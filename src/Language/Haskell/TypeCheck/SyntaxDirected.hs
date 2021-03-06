-- Syntax-directed typing rules.
module Language.Haskell.TypeCheck.SyntaxDirected where


import           Control.Monad
import           Control.Monad.Except
import           Data.Graph                             (flattenSCC,
                                                         stronglyConnComp)
import           Data.List
import           Data.Maybe
import           Data.STRef
import           Language.Haskell.Exts.SrcLoc
import           Language.Haskell.Exts.Syntax

import           Language.Haskell.Scope                 (GlobalName (..),
                                                         NameInfo (..),
                                                         Origin (..))
import           Language.Haskell.TypeCheck.Debug
import           Language.Haskell.TypeCheck.Misc
import           Language.Haskell.TypeCheck.Monad
import           Language.Haskell.TypeCheck.Proof
import           Language.Haskell.TypeCheck.Subsumption
import           Language.Haskell.TypeCheck.Types       hiding (Type (..),
                                                         Typed (..))
import           Language.Haskell.TypeCheck.Unify

import qualified Language.Haskell.TypeCheck.Pretty      as Doc

-- tiGuardedAlts :: GuardedAlts Origin -> TI TcType
-- tiGuardedAlts galts =
--     case galts of
--         UnGuardedAlt _ branch -> tiExp branch
--         _ -> error "tiGuardedAlts"

tiAlt :: Rho s -> ExpectedRho s -> Alt (Pin s) -> TI s ()
tiAlt scrutTy exp_ty (Alt _ pat rhs _mbBinds) = do
  checkRho (tiPat pat) scrutTy
  tiRhs rhs exp_ty

tiLit :: Literal (Pin s) -> ExpectedRho s -> TI s ()
tiLit lit exp_ty = do
  ty <- case lit of
    PrimInt{} -> return (TcCon (mkBuiltIn "LHC.Prim" "I64"))
    PrimString{} -> return $ TcApp
      (TcCon (mkBuiltIn "LHC.Prim" "Addr"))
      (TcCon (mkBuiltIn "LHC.Prim" "I8"))
    PrimChar{} -> return $ TcCon (mkBuiltIn "LHC.Prim" "I32")
    Int{} -> return $ TcCon (mkBuiltIn "LHC.Prim" "Int")
    Char{} -> return $ TcCon (mkBuiltIn "LHC.Prim" "Char")
    _ -> error $ "tiLit: " ++ show lit
  _coercion <- instSigma ty exp_ty
  -- Hm, what to do with the proof here. We need it for overloaded constants
  -- such as numbers and Strings (iff OverloadedStrings enabled).
  -- For now we can just ignore it.
  return ()

-- tiQOp :: QOp Origin -> TI s (TcType s)
-- tiQOp op =
--     case op of
--         QVarOp src var -> tiExp (Var src var)
--         QConOp src con -> tiExp (Con src con)

-- tiStmts :: [Stmt Origin] -> TI s (TcType s)
-- tiStmts [] = error "tiStmts: empty list"
-- tiStmts [stmt] =
--   case stmt of
--     Generator{} -> error $ "tiStmts: " ++ show [stmt]
--     Qualifier _ expr -> tiExp expr
--     _ -> error $ "tiStmts: " ++ show stmt
-- tiStmts (stmt:stmts) =
--   case stmt of
--     Generator (Origin _ pin) pat expr -> do
--       ty <- TcMetaVar <$> newTcVar
--
--       patTy <- tiPat pat
--       exprTy <- tiExp expr
--       restTy <- tiStmts stmts
--
--       (TcQual _preds bindIOTy, coercion) <- freshInst bindIOSig
--       let ioPatTy = ioType `TcApp` patTy
--
--       unify ioPatTy exprTy -- IO patTy == exprTy
--       unify bindIOTy (exprTy `TcFun` ((patTy `TcFun` restTy) `TcFun` (ioType `TcApp` ty))) -- bindIO == expr -> (pat -> rest) -> IO _
--
--       setCoercion pin coercion
--
--       return restTy
--
--     Qualifier (Origin _ pin) expr -> do
--       ty <- TcMetaVar <$> newTcVar
--       exprTy <- tiExp expr
--       restTy <- tiStmts stmts
--
--       (TcQual _preds thenIOTy, coercion) <- freshInst thenIOSig
--       unify thenIOTy (exprTy `TcFun` (restTy `TcFun` (ioType `TcApp` ty)))
--
--       setCoercion pin coercion
--
--       return restTy
--     _ -> error $ "tiStmts: " ++ show (stmt:stmts)

consSigma :: TcType s
consSigma = TcForall [aRef] (TcQual [] (aTy `TcFun` (TcList aTy `TcFun` TcList aTy)))
  where
    aRef = TcVar "a" []
    aTy = TcRef aRef

-- forall a b. IO a -> IO b -> IO b
thenIOSig :: TcType s
thenIOSig = TcForall [aRef, bRef] (TcQual [] (ioA `TcFun` (ioB `TcFun` ioB)))
  where
    aRef = TcVar "a" []
    bRef = TcVar "b" []
    ioA = ioType `TcApp` TcRef aRef
    ioB = ioType `TcApp` TcRef bRef

-- forall a b. IO a -> (a -> IO b) -> IO b
bindIOSig :: TcType s
bindIOSig = TcForall [aRef, bRef] (TcQual [] (ioA `TcFun` ((TcRef aRef `TcFun` ioB) `TcFun` ioB)))
  where
    aRef = TcVar "a" []
    bRef = TcVar "b" []
    ioA = ioType `TcApp` TcRef aRef
    ioB = ioType `TcApp` TcRef bRef

ioType :: TcType s
ioType = TcCon (mkBuiltIn "LHC.Prim" "IO")

tiQName :: QName (Pin s) -> Expected s (Rho s) -> TI s ()
tiQName (Special _ UnitCon{}) exp_ty = unifyExpected (TcTuple []) exp_ty
tiQName (Special pin Cons{}) exp_ty = do
  coercion <- instSigma consSigma exp_ty
  setProof pin coercion consSigma
tiQName (UnQual _src name) exp_ty = do
  let pin = ann name
  gname <- expectResolvedPin pin
  tySig <- findAssumption gname
  -- debug $ "Var: " ++ show (P.pretty tySig)
  coercion <- instSigma tySig exp_ty
  -- Proofs for recursive variables are set once all the mutually recursive
  -- variables have been type checked. Thus, instead of setting the proof
  -- now, we just note down the location (pin) and add the proof later.
  isRec <- isRecursive gname
  if isRec
    then setKnot gname pin
    else setProof pin coercion tySig

tiExp ::  Exp (Pin s) -> Expected s (Rho s) -> TI s ()
tiExp expr exp_ty =
  case expr of
    Case _ scrut alts -> do
      scrutTy <- inferRho (tiExp scrut)
      mapM_ (tiAlt scrutTy exp_ty) alts
    Var _ qname -> tiQName qname exp_ty
    Con _ (Special _ UnitCon{}) -> unifyExpected (TcTuple []) exp_ty
    Con _ (Special pin Cons{}) -> do
      coercion <- instSigma consSigma exp_ty
      setProof pin coercion consSigma
    Con _ conName -> tiQName conName exp_ty
    -- Con _ conName -> do
    --   let pin = ann conName
    --   gname <- qnameToGlobalName conName
    --   tySig <- findAssumption gname
    --   coercion <- instSigma tySig exp_ty
    --   setProof pin coercion tySig
    InfixApp _ a (QConOp _ qname) b -> do
      fnTy <- inferRho (tiQName qname)
      (a_ty, b_ty, res_ty) <- unifyFun2 fnTy
      checkSigma (ann a) (tiExp a) a_ty
      checkSigma (ann b) (tiExp b) b_ty
      _coercion <- instSigma res_ty exp_ty
      return ()
    InfixApp _ a (QVarOp _ qname) b -> do
      fnTy <- inferRho (tiQName qname)
      (a_ty, b_ty, res_ty) <- unifyFun2 fnTy
      checkSigma (ann a) (tiExp a) a_ty
      checkSigma (ann b) (tiExp b) b_ty
      _coercion <- instSigma res_ty exp_ty
      return ()
      -- a `fn` b :: exp_ty
      -- fn :: a -> b -> exp_ty
    App _ fn a -> do
      fnT <- inferRho (tiExp fn)
      (arg_ty, res_ty) <- unifyFun fnT
      -- debug $ "ArgTy: " ++ show (P.pretty arg_ty)
      let pin = ann a
      checkSigma pin (tiExp a) arg_ty

      -- debug $ "App pin: " ++ show pin
      -- setProof pin argCoercion arg_ty
      _coercion <- instSigma res_ty exp_ty
      -- Hm, what to do with the coercion?
      return ()
    -- InfixApp _ a op b -> do
    --     ty <- TcMetaVar <$> newTcVar
    --     opT <- tiQOp op
    --     aT <- tiExp a
    --     bT <- tiExp b
    --     unify (TcFun aT (TcFun bT ty)) opT
    --     return ty
    Paren _ e -> tiExp e exp_ty
    -- -- \a b c -> d
    -- -- :: a -> b -> c -> d
    Lambda _ pats e | Check rho <- exp_ty -> do
      -- debug $ "CheckLambda: " ++ show (P.pretty rho)
      (patTys, resTy) <- unifyFuns (length pats) rho
      forM_ (zip patTys pats) $ \(patTy, pat) -> checkRho (tiPat pat) patTy
      checkRho (tiExp e) resTy
    Lambda _ pats e | Infer ref <- exp_ty -> do
      patTys <- forM pats $ inferRho . tiPat
      resTy <- inferRho (tiExp e)
      liftST $ writeSTRef ref (foldr TcApp resTy patTys)
    Lit _ lit -> tiLit lit exp_ty
    Tuple _ Unboxed args | Check rho <- exp_ty -> do
      argTys <- unifyUnboxedTuple (length args) rho
      forM_ (zip argTys args) $ \(argTy,arg) -> checkRho (tiExp arg) argTy
    Tuple _ Unboxed args | Infer ref <- exp_ty -> do
      argTys <- forM args $ inferRho . tiExp
      liftST $ writeSTRef ref (TcUnboxedTuple argTys)
    Tuple _ Boxed args | Check rho <- exp_ty -> do
      argTys <- unifyTuple (length args) rho
      forM_ (zip argTys args) $ \(argTy,arg) -> checkRho (tiExp arg) argTy
    Let _ binds subExpr -> do
      tiBinds binds
      tiExp subExpr exp_ty
    List pin exprs -> do
      eltTy <- unifyList =<< expectList exp_ty
      setProof pin (`TcProofAp` [eltTy]) eltTy
      forM_ exprs $ \expr' -> checkRho (tiExp expr') eltTy
    -- Do _ stmts -> tiStmts stmts
    _ -> error $ "tiExp: " ++ show expr

findConAssumption :: QName (Pin s) -> TI s (TcType s)
findConAssumption qname = case qname of
    Special _ con -> case con of
        UnitCon{} -> return (TcTuple [])
        ListCon{} -> do
            ty <- TcMetaVar <$> newTcVar
            return $ TcList ty
        Cons{} -> do
            ty <- TcMetaVar <$> newTcVar
            return $ ty `TcFun` (TcList ty `TcFun` TcList ty)
        _ -> error "Language.Haskell.TypeCheck.SyntaxDirected.findConAssumption: Unhandled con type."
    _ -> do
        gname <- qnameToGlobalName qname
        findAssumption gname

tiPat :: Pat (Pin s) -> ExpectedRho s -> TI s ()
tiPat thisPat exp_ty =
  case thisPat of
    PVar _ name -> do
      let pin = ann name
      gname <- expectResolvedPin pin
      ty <- expectAny exp_ty
      setAssumption gname ty
      setProof pin id ty
    -- con :: p1 -> p2 -> ... -> ret
    -- con pat1 pat2 ...
    PApp _ con pats -> do
      conSig <- findConAssumption con
      (conTy, _coercion) <- instantiate conSig
      (patTys, retTy) <- unifyFuns (length pats) conTy
      forM_ (zip patTys pats) $ \(patTy, pat) -> checkRho (tiPat pat) patTy
      _coercion <- instSigma retTy exp_ty
      return ()
    PWildCard _ -> return ()
    PParen _ sub -> tiPat sub exp_ty
    PTuple _ Unboxed pats -> do
      ty <- expectAny exp_ty
      patTys <- unifyUnboxedTuple (length pats) ty
      forM_ (zip patTys pats) $ \(patTy, pat) -> checkRho (tiPat pat) patTy
    PLit _ _sign literal ->
      tiLit literal exp_ty
    PList _ pats -> do
      eltTy <- unifyList =<< expectList exp_ty
      forM_ pats $ \pat' -> checkRho (tiPat pat') eltTy
    PInfixApp _ a con b -> do
      conSig <- findConAssumption con
      (conTy, _coercion) <- instantiate conSig
      (patTys, retTy) <- unifyFuns 2 conTy
      forM_ (zip patTys [a,b]) $ \(patTy, pat) -> checkRho (tiPat pat) patTy
      _coercion <- instSigma retTy exp_ty
      return ()
    _ -> error $ "tiPat: " ++ show thisPat

tiRhs :: Rhs (Pin s) -> ExpectedRho s -> TI s ()
tiRhs rhs exp_ty =
  case rhs of
    UnGuardedRhs _ expr ->
      tiExp expr exp_ty
    _ -> error "tiRhs"

tiMatch :: Match (Pin s) -> ExpectedRho s -> TI s ()
tiMatch match exp_ty =
    case match of
      Match _ _ pats rhs mbBinds -> do
        ty <- expectAny exp_ty
        (patTys, retTy) <- unifyFuns (length pats) ty
        forM_ (zip patTys pats) $ \(patTy, pat) -> checkRho (tiPat pat) patTy
        maybe (return ()) tiBinds mbBinds
        checkRho (tiRhs rhs) retTy
      InfixMatch _ leftPat _ rightPats rhs mbBinds -> do
        maybe (return ()) tiBinds mbBinds
        ty <- expectAny exp_ty
        (patTys, retTy) <- unifyFuns (length $ leftPat:rightPats) ty
        forM_ (zip patTys (leftPat:rightPats)) $ \(patTy, pat) -> checkRho (tiPat pat) patTy
        checkRho (tiRhs rhs) retTy

--matchPatterns :: Match l -> Int
--matchPatterns (Match _ _ paths _ _) = length paths
--matchPatterns InfixMatch{} = 2

tiBinds :: Binds (Pin s) -> TI s ()
tiBinds binds =
    case binds of
        BDecls _ decls -> tiBindGroup decls
        _ -> error "Language.Haskell.TypeCheck.Infer.tiBinds"

tiDecl :: Decl (Pin s) -> ExpectedRho s -> TI s ()
tiDecl decl exp_ty =
  case decl of
    FunBind _ matches -> do
      mapM_ (\match -> tiMatch match exp_ty) matches
    PatBind _ _pat rhs binds -> do
      maybe (return ()) tiBinds binds
      tiRhs rhs exp_ty
    _ -> error $ "tiDecl: " ++ show decl

declIdent :: Decl (Pin s) -> SrcLoc
declIdent decl =
    case decl of
        FunBind _ (Match _ name _ _ _:_) ->
            let Pin (Origin _ src) _ = ann name
            in getPointLoc src
        _ -> error "declIdent"

--tiImpls :: [Decl Origin] -> TI ()
--tiImpls impls = do
--    forM_ impls $ \impl -> do
--        ty <- TcMetaVar <$> newTcVar
--        setAssumption (declIdent impl) ty
--        tiDecl impl ty
--        rTy <- zonk ty
--        liftIO $ print rTy
    -- qualify the type sigs...

declHeadType :: DeclHead (Pin s) -> ([TcVar], GlobalName)
declHeadType dhead =
    case dhead of
        DHead _ name ->
            let Pin (Origin (Binding gname) _) _ = ann name
            in ([], gname)
        DHApp _ dh tyVarBind ->
            let (tcVars, gname) = declHeadType dh
                var = tcVarFromTyVarBind tyVarBind
            in (tcVars ++ [var], gname)
        _ -> error "declHeadType"
  where
    tcVarFromTyVarBind (KindedVar _ name _) = tcVarFromName name
    tcVarFromTyVarBind (UnkindedVar _ name) = tcVarFromName name

instHeadType :: InstHead (Pin s) -> TI s ([TcType s], GlobalName)
instHeadType ihead =
  case ihead of
    IHCon _ qname -> do
      gname <- qnameToGlobalName qname
      return ([], gname)
    IHInfix _ ty qname -> do
      ty' <- typeToTcType ty
      gname <- qnameToGlobalName qname
      return ([ty'], gname)
    IHParen _ ih -> instHeadType ih
    IHApp _ ih ty -> do
      ty' <- typeToTcType ty
      (tys, gname) <- instHeadType ih
      return (tys ++ [ty'], gname)

tiConDecl :: [TcVar] -> TcType s -> ConDecl (Pin s) -> TI s (GlobalName, [TcType s])
tiConDecl tvars dty conDecl =
    case conDecl of
        ConDecl _ con tys -> do
            let Pin (Origin (Binding gname) _) _ = ann con
            -- setCoercion (globalNameSrcSpanInfo gname) (TcProofAbs tvars)
            tys' <- mapM typeToTcType tys
            return (gname, tys')
        RecDecl _ con fields -> do
            conTys <- concat <$> sequence
                    [ replicateM (length names) (typeToTcType ty)
                    | FieldDecl _ names ty <- fields ]
            forM_ fields $ \(FieldDecl _ names fTy) -> do
                ty <- TcFun dty <$> typeToTcType fTy
                forM_ names $ \name -> do
                    gname <- expectResolvedPin (ann name)
                    setAssumption gname (TcForall tvars $ TcQual [] ty)
            gname <- expectResolvedPin (ann con)
            return (gname, conTys)
        _ -> error "tiConDecl"

tiQualConDecl :: [TcVar] -> TcType s -> QualConDecl (Pin s) ->
                 TI s (GlobalName, [TcType s])
tiQualConDecl tvars dty (QualConDecl _ _ _ con) =
    tiConDecl tvars dty con

tiClassDecl :: Decl (Pin s) -> TI s ()
tiClassDecl decl =
    case decl of
        -- ClassDecl _ _ctx (DHead _ className [tyBind]) _deps (Just decls) ->
        --     sequence_
        --         [ worker className tyBind name ty
        --         | ClsDecl _ (TypeSig _ names ty) <- decls, name <- names ]
        _ -> error "tiClassDecl"
  where
    -- tcVarFromName :: Name Origin -> TcVar
    -- tcVarFromTyVarBind (KindedVar _ name _) = tcVarFromName name
    -- tcVarFromTyVarBind (UnkindedVar _ name) = tcVarFromName name
    -- worker className tyBind name ty = do
    --     -- name :: className tybind => ty
    --     let Origin (Resolved gname) _ = ann className
    --         Origin (Resolved (GlobalName src _qname)) _ = ann name
    --         tcVar = tcVarFromTyVarBind tyBind
    --         tcType = typeToTcType ty
    --     let scheme = TcForall [tcVar] ([IsIn gname (TcRef tcVar)] :=> tcType)
    --     setAssumption src scheme

tiPrepareClassDecl :: GlobalName -> [TcVar] -> ClassDecl (Pin s) -> TI s ()
tiPrepareClassDecl className [tyVar] decl =
    case decl of
      ClsDecl _ (TypeSig _ names ty) -> do
        forM_ names $ \name -> do
          gname <- expectResolvedPin (ann name)
          ty' <- typeToTcType ty
          free <- getFreeTyVars [ty']
          setAssumption gname
            (TcForall free ([TcIsIn className (TcRef tyVar)] `TcQual` ty'))
      _ -> error $ "tiPrepareClassDecl: " ++ show decl
tiPrepareClassDecl _ _ decl =
    error $ "tiPrepareClassDecl: " ++ show decl

tiPrepareDecl :: Decl (Pin s) -> TI s ()
tiPrepareDecl decl =
    case decl of
        DataDecl _ _ _ dhead cons _ -> do
            let (tcvars, GlobalName _ qname) = declHeadType dhead
                dataTy = foldl TcApp (TcCon qname) (map TcRef tcvars)
            forM_ cons $ \qualCon -> do
                (con, fieldTys) <- tiQualConDecl tcvars dataTy qualCon
                let ty = foldr TcFun dataTy fieldTys
                -- setProof (globalNameSrcSpanInfo con) (tcProofAbs tcvars) ty
                setAssumption con (TcForall tcvars $ TcQual [] ty)
        FunBind{} -> return ()
        PatBind{} -> return ()
        TypeDecl{} -> return ()
        ForImp _ _conv _safety _mbExternal name ty -> do
            gname <- expectResolvedPin (ann name)
            setAssumption gname =<< typeToTcType ty
        TypeSig _ names ty ->
            forM_ names $ \name -> do
                gname <- expectResolvedPin (ann name)
                setAssumption gname =<< explicitTcForall =<< typeToTcType ty
                --setCoercion (nameIdentifier name)
                --    (CoerceAbs (freeTcVariables $ typeToTcType ty))
        ClassDecl _ mbCtx dhead _funDeps mbDecls -> do
          let ([tcvar], className) = declHeadType dhead
          constraints <- tiMaybe [] contextToPredicates mbCtx
          let classDef = TcQual constraints (TcIsIn className (TcRef tcvar))
          addClass classDef

          forM_ (fromMaybe [] mbDecls) $ \clsDecl ->
            tiPrepareClassDecl className [tcvar] clsDecl
        InstDecl _ _mbOverlap instRule _mbInstDecls -> do
          tiPrepareInstDecl instRule
        _ -> error $ "tiPrepareDecl: " ++ show decl

tiPrepareInstDecl :: InstRule (Pin s) -> TI s ()
tiPrepareInstDecl (IParen _ instRule) = tiPrepareInstDecl instRule
tiPrepareInstDecl (IRule _ _binds mbCtx instHead) = do
  constraints <- tiMaybe [] contextToPredicates mbCtx
  ([ty], className) <- instHeadType instHead
  let instDef = TcQual constraints (TcIsIn className ty)
  addInstance instDef


{-
Story about predicates:
Split type signature into a rho type and a list of starting predicates.
Get list of predicates we got from type-checking.
Remove predicates that are entailed by our starting predicates.
Simplify predicates.
Defer predicates that refer to outer meta variables.
If any predicates are left using skolem variables:
  Context is too weak: Variable needed constraint which couldn't be found.
  Example: fn :: a -> String; fn x = show x
If any predicates are left using meta variables:
  Example: fn x = show . read
-}
tiExpl :: (Decl (Pin s), GlobalName) -> TI s ()
tiExpl (decl, binder) = do
  setPredicates []
  sigma <- findAssumption binder
  -- Hm, we need to do something with the 'tvs' but I can't see what.
  (tvs, preds, rho, prenexToSigma) <- skolemize sigma
  -- debug $ "tiExpl: " ++ show (Doc.pretty binder) ++ " :: " ++ show (Doc.pretty rho)
  -- debug $ "tiExpl: " ++ "Before: " ++ show (Doc.pretty preds)
  checkRho (tiDecl decl) rho
  afterPreds <- filterM (fmap not . entail preds) =<< mapM lowerPredMetaVars =<< getPredicates
  -- debug $ "tiExpl: " ++ "After: " ++ show (Doc.pretty afterPreds)
  outer_meta <- getFreeMetaVariables
  rs <- simplifyAndDeferPredicates outer_meta afterPreds
  -- debug $ "tiExpl: " ++ "Kept: " ++ show (Doc.pretty rs)
  unless (null rs) $ throwError ContextTooWeak
  setProof (ann decl) (prenexToSigma) (TcForall tvs (TcQual preds rho))

{-
Predicates:
  collect predicates
  reduce/simplify predicates
  defer all predicates that refer to outer meta variables.
  default all predicates that don't refer to inner meta variables.
  quantify type signatures with predicates
-}
tiDecls :: [(Decl (Pin s), GlobalName)] -> TI s ()
tiDecls decls = withRecursive thisBindGroup $ do
    -- debug $ "Bind group: " ++ dshow False (map snd decls)
    outer_meta <- getFreeMetaVariables
    forM_ decls $ \(_decl, binder) -> do
        ty <- TcMetaVar <$> newTcVar
        setAssumption binder ty
    forM_ decls $ \(decl, binder) -> do
        ty <- findAssumption binder
        -- debug_ty <- resolveMetaVars ty
        -- debug $ dshow False binder ++ " :: " ++ show (Doc.pretty debug_ty) ++ " (start)"
        -- invariant: ty is Rho, not Sigma.
        checkRho (tiDecl decl) ty
        -- debug_ty <- resolveMetaVars ty
        -- debug $ dshow False binder ++ " :: " ++ show (Doc.pretty debug_ty) ++ " (end)"

    _preds <- getPredicates
    -- forM_ _preds $ debug . show . Doc.pretty

    knots <- getKnots
    outer_meta' <- getMetaTyVars $ map TcMetaVar outer_meta

    afterPreds <- mapM lowerPredMetaVars =<< getPredicates
    -- debug $ "tiDecls: " ++ "Outer: " ++ show (Doc.pretty outer_meta')
    -- debug $ "tiDecls: " ++ "After: " ++ show (Doc.pretty afterPreds)
    rs <- simplifyAndDeferPredicates outer_meta' =<< reduce afterPreds
    -- debug $ "tiDecls: " ++ "Keep:  " ++ show (Doc.pretty rs)

    forM_ decls $ \(decl, binder) -> do
        ty <- findAssumption binder
        (gTy, tvs) <- quantify outer_meta' rs ty
        -- debug_gTy <- resolveMetaVars gTy
        -- debug $ dshow False binder ++ " :: " ++ show (Doc.pretty debug_gTy) ++ " (knot)"
        -- setProof (ann decl) (flip tcProofAp (map TcRef tvs) . tcProofAbs tvs) gTy
        setProof (ann decl) id gTy
        -- debug $ show $ Doc.pretty gTy
        setAssumption binder gTy

        forM_ knots $ \(thisBinder, usageLoc) ->
          when (binder == thisBinder) $
            setProof usageLoc (`TcProofAp` map TcRef tvs) gTy

    decl_meta <- getMetaTyVars =<< mapM (findAssumption.snd) decls
    -- debug $ "Bind group end: " ++ show decl_meta
    -- debug $ "              : " ++ show outer_meta'
    let meta = decl_meta \\ outer_meta'
        tvs = map toTcVar meta
    forM_ (zip meta tvs) $ \(var, ty) -> writeMetaVar var (TcRef ty)
  where
    thisBindGroup = map snd decls
    toTcVar (TcMetaRef name _) = TcVar name []



    --error $ "tiDecls: " ++ show decls

-- First go through the declarations and add explicit type signatures to
-- the environment. Then type check the implicit declarations in their
-- strongly connected groups. Lastly, verify the signature of explicitly
-- typed declarations (this includes instance methods).
tiBindGroup :: [Decl (Pin s)] -> TI s ()
tiBindGroup decls = do
    -- liftIO $ putStrLn $ "Explicit: " ++ show explicitlyTyped
    mapM_ tiPrepareDecl decls
    forM_ scc $ tiDecls . flattenSCC
    forM_ explicitDecls tiExpl
  where
    explicitlyTyped =
        [ nameIdentifier name
        | TypeSig _ names _ <- decls
        , name <- names ]
    explicitDecls =
        [ (decl, binder)
        | decl <- decls
        , binder <- declBinders decl
        , binder `elem` explicitlyTyped ]
    graph =
        [ ((decl, binder), binder, declFreeVariables decl )
        | decl <- decls
        , binder <- declBinders decl
        , binder `notElem` explicitlyTyped ]
    scc = stronglyConnComp graph

-- FIXME: Rename this function. We're not finding free variables, we finding
--        all references.
declFreeVariables :: Decl (Pin s) -> [GlobalName]
declFreeVariables decl =
    case decl of
        FunBind _ matches -> concatMap freeMatch matches
        PatBind _ _pat rhs binds -> freeRhs rhs ++ freeBinds binds
        _ -> error $ "declFreeVariables: " ++ show decl
  where
    freeBinds Nothing = []
    freeBinds (Just (BDecls _src decls)) = concatMap declFreeVariables decls
    freeBinds _ = error "declFreeVariables, freeBinds"
    freeMatch match =
        case match of
            Match _ _ _pats rhs mbBinds -> freeRhs rhs ++ freeBinds mbBinds
            _ -> error "declFreeVariables, freeMatch"
    freeRhs rhs =
        case rhs of
            UnGuardedRhs _ expr -> freeExp expr
            _ -> error "declFreeVariables, freeRhs"
    freeExp expr =
        case expr of
            Var _ qname -> [qnameIdentifier qname]
            Con{} -> []
            Lit{} -> []
            Case _ scrut alts -> freeExp scrut ++ concatMap freeAlt alts
            App _ a b -> freeExp a ++ freeExp b
            InfixApp _ a op b -> freeExp a ++ freeQOp op ++ freeExp b
            Paren _ e -> freeExp e
            Lambda _ _pats e -> freeExp e
            Do _ stmts -> concatMap freeStmt stmts
            Tuple _ _ exprs -> concatMap freeExp exprs
            List _ exprs -> concatMap freeExp exprs
            _ -> error $ "freeExp: " ++ show expr
    freeStmt stmt =
        case stmt of
            Generator _ _pat expr -> freeExp expr
            Qualifier _ expr -> freeExp expr
            _ -> error $ "freeStmt: " ++ show stmt
    freeQOp op =
        case op of
            QVarOp _ qname -> [qnameIdentifier qname]
            QConOp{} -> []
    freeAlt (Alt _ _pat rhs _binds) = freeRhs rhs

qnameIdentifier :: QName (Pin s) -> GlobalName
qnameIdentifier qname =
    case qname of
        Qual _ _ name -> nameIdentifier name
        UnQual _ name -> nameIdentifier name
        _ -> error "qnameIdentifier"

nameIdentifier :: Name (Pin s) -> GlobalName
nameIdentifier name =
    case info of
        Resolved gname -> gname
        _ -> error "nameIdentifier"
  where
    Pin (Origin info _) _ = ann name

declBinders :: Decl (Pin s) -> [GlobalName]
declBinders decl =
    case decl of
        DataDecl{} -> []
        ForImp{}   -> []
        FunBind (Pin (Origin (Binding gname) _src) _) matches -> [gname]
        PatBind _ pat _rhs _binds ->
            patBinders pat
        TypeDecl{} -> []
        TypeSig{} -> []
        ClassDecl{} -> []
        InstDecl{} -> []
        _ -> error $ "declBinders: " ++ show decl

patBinders :: Pat (Pin s) -> [GlobalName]
patBinders pat =
    case pat of
        PVar _ name ->
            let Pin (Origin (Binding gname) _) _ = ann name
            in [gname]
        _ -> error $ "patBinders: " ++ show pat

tiModule :: Module (Pin s) -> TI s ()
tiModule m =
    case m of
        Module _ _dhead _pragma _imports decls ->
            tiBindGroup decls
        _ -> error "tiModule"
