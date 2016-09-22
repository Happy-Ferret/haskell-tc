module Language.Haskell.TypeCheck.RankN where

import Language.Haskell.TypeCheck.Types
import Language.Haskell.TypeCheck.Monad hiding (getMetaTyVars)
import Language.Haskell.TypeCheck.Misc

import Control.Monad
import Data.List
import Data.STRef

type Term = ()

instantiate :: Sigma s -> TI s (Rho s, Coercion s)
instantiate (TcForall tvs (TcQual [] ty)) = do
  undefined
instantiate tau = return (tau, id)

{-
skolemize sigma = /\a.rho + f::/\a.rho -> sigma

Skolemize hoists all forall's to the top-level and returns a coercion function
from the new sigma type to the old sigma type.
-}
skolemize :: Sigma s -> TI s ([TcVar], Rho s, Coercion s)
-- skolemize (TcForAll tvs ty) = do
--   sks1 <- mapM newSkolemTyVars tyvas
--   (sks2, ty', f) <- skolemize (substTy tvs (map TyVar sks1) ty)
--   return (sks1 ++ sks2, ty', CoerceAbsAp sks1 f)
-- skolemize (TcFun arg_ty res_ty) = do
--   (sks, res_ty', f) <- skolemize res_ty
--   return (sks, TcFun arg_ty res_ty', CoerceFunAbsAp sks f)
skolemize ty =
  return ([], ty, id)

quantify :: [TcMetaVar s] -> Rho s -> TI s (Sigma s, Coercion s)
quantify = undefined

unifyFun :: Tau s -> TI s (Sigma s, Rho s)
unifyFun (TcFun a b) = return (a,b)
unifyFun ty = do
  a <- TcMetaVar <$> newTcVar
  b <- TcMetaVar <$> newTcVar
  unify ty (TcFun a b)
  return (a, b)

tcRho :: Term -> Expected s (Rho s) -> TI s ()
tcRho = undefined

checkRho :: Term -> Rho s -> TI s ()
checkRho term ty = tcRho term (Check ty)

inferRho :: Term -> TI s (Rho s)
inferRho term = do
  ref <- liftST $ newSTRef (error "inferRho: empty result")
  tcRho term (Infer ref)
  liftST $ readSTRef ref

inferSigma :: Term -> TI s (Sigma s)
inferSigma term = do
  exp_ty <- inferRho term
  env_tys <- getEnvTypes
  env_tvs <- getMetaTyVars env_tys
  res_tvs <- getMetaTyVars [exp_ty]
  let forall_tvs = res_tvs \\ env_tvs
  (sigma, rhoToSigma) <- quantify forall_tvs exp_ty
  return sigma

checkSigma :: Term -> Sigma s -> TI s ()
checkSigma term sigma = do
  (skol_tvs, rho, p) <- skolemize sigma
  checkRho term rho
  env_tys <- getEnvTypes
  esc_tvs <- getFreeTyVars (sigma : env_tys)
  let bad_tvs = filter (`elem` esc_tvs) skol_tvs
  unless (null bad_tvs) $ error "Type not polymorphic enough"
  -- let coercion = CoerceAbs skol_tvs
  return ()

-- Rule DEEP-SKOL
-- subsCheck offered_type expected_type
-- coercion :: Sigma1 -> Sigma2
subsCheck :: TcType s -> TcType s -> TI s (Coercion s)
subsCheck sigma1 sigma2 = do
  (skol_tvs, rho2, forallrho2ToSigma2) <- skolemize sigma2
  sigma1ToRho2 <- subsCheckRho sigma1 rho2
  esc_tvs <- getFreeTyVars [sigma1, sigma2]
  let bad_tvs = filter (`elem` esc_tvs) skol_tvs
  unless (null bad_tvs) $ error "Subsumption check failed"
  -- /\a.rho = sigma2
  -- \sigma1 -> forallrho2ToSigma2 (/\a. sigma1ToRho2 sigma1)
  -- return (CoerceCompose (CoerceAbs skol_tvs) sigma2ToRho2)
  return $ \x -> forallrho2ToSigma2 (ProofAbs skol_tvs (sigma1ToRho2 x))

-- instSigma ((forall a. a -> a) -> Int) ((forall a b. a -> b) -> Int)
--     = CoerceFun Id (subsCheck (forall a b. a -> b) (forall a. a -> a))
-- subsCheck (forall a b. a -> b) (forall a. a -> a)
--     = Compose (Abs [a]) (subsCheckRho (forall a b. a -> b) (a -> a))
--     = Compose (Abs [a]) (Compose Id (Ap [a,b]))

-- (forall ab. a -> b)          (a -> a) = Compose  (subsCheckRho (a -> b) (a -> a)) (Ap [a,b])
-- subsCheckRho (a -> b) (a -> a) = CoerceFun (subCheckRho b a) (subsCheck a a) = CoerceFun Id Id
-- subsCheckRho tau tau = Id
subsCheckRho :: Sigma s -> Rho s -> TI s (Coercion s)
subsCheckRho sigma1@TcForall{} rho2 = do
  (rho1, sigma1ToRho1) <- instantiate sigma1
  rho1ToRho2 <- subsCheckRho rho1 rho2
  let sigma1ToRho2 = rho1ToRho2 . sigma1ToRho1
  return sigma1ToRho2
subsCheckRho t1 (TcFun a2 r2) = do
  (a1, r1) <- unifyFun t1
  subsCheckFun a1 r1 a2 r2
subsCheckRho (TcFun a1 r1) t2 = do
  (a2, r2) <- unifyFun t2
  subsCheckFun a1 r1 a2 r2
subsCheckRho tau1 tau2 = do
  unify tau1 tau2
  return id

subsCheckRhoRho :: Rho s -> Rho s -> TI s (Coercion s)
subsCheckRhoRho t1 (TcFun a2 r2) = do
  (a1, r1) <- unifyFun t1
  subsCheckFun a1 r1 a2 r2
subsCheckRhoRho (TcFun a1 r1) t2 = do
  (a2, r2) <- unifyFun t2
  subsCheckFun a1 r1 a2 r2
subsCheckRhoRho t1 t2 = do
  unify t1 t2
  return id

-- subsCheckFun (a1 -> r1) (a2 -> r2)
-- coercion :: (a1 -> r1) -> (a2 -> r2)
subsCheckFun :: Sigma s -> Rho s -> Sigma s -> Rho s -> TI s (Coercion s)
subsCheckFun a1 r1 a2 r2 = do
  co_arg <- subsCheck a2 a1
  -- co_arg :: a2 -> a1
  co_res <- subsCheckRho r1 r2
  -- co_res :: r1 -> r2
  u <- newUnique
  return $ \x -> ProofLam u a2 (co_res (x `ProofAp` co_arg (ProofVar u)))



-- We have type 'Sigma' and we want type 'Rho'. The coercion is a function of
-- type Sigma->Rho
instSigma :: Sigma s -> Expected s (Rho s) -> TI s (Coercion s)
instSigma ty (Infer r) = do
  (ty', coerce) <- instantiate ty
  liftST $ writeSTRef r ty'
  return coerce
instSigma ty (Check rho) = subsCheckRho ty rho
