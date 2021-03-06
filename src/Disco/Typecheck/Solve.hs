{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Disco.Typecheck.Solve
-- Copyright   :  (c) 2018 disco team (see LICENSE)
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  byorgey@gmail.com
--
-- Constraint solver for the constraints generated during type
-- checking/inference.
-----------------------------------------------------------------------------

module Disco.Typecheck.Solve where

import           Prelude                          hiding (lookup)
import qualified Prelude                          as P

import           Unbound.Generics.LocallyNameless

import           Control.Monad.Except
import           Control.Monad.State
import           Data.Coerce
import           GHC.Generics                     (Generic)

import           Control.Arrow                    ((&&&), (***))
import           Control.Lens
import           Data.Bifunctor                   (second)
import           Data.Either                      (isRight, partitionEithers)
import           Data.List                        (find, foldl', intersect,
                                                   partition)
import           Data.Map                         (Map, (!))
import qualified Data.Map                         as M
import           Data.Maybe                       (catMaybes, fromJust,
                                                   fromMaybe)
import           Data.Semigroup
import           Data.Set                         (Set)
import qualified Data.Set                         as S
import           Data.Tuple

import           Disco.Subst
import           Disco.Typecheck.Constraints
import           Disco.Typecheck.Graph            (Graph)
import qualified Disco.Typecheck.Graph            as G
import           Disco.Typecheck.Unify
import           Disco.Types
import           Disco.Types.Rules

import qualified Debug.Trace                      as Debug

traceM :: Applicative f => String -> f ()
traceM _ = pure ()
-- traceM = Debug.traceM

traceShowM :: (Show a, Applicative f) => a -> f ()
traceShowM _ = pure ()
-- traceShowM = Debug.traceShowM

--------------------------------------------------
-- Solver errors

-- | Type of errors which can be generated by the constraint solving
--   process.
data SolveError where
  NoWeakUnifier :: SolveError
  NoUnify       :: SolveError
  UnqualBase    :: Qualifier -> BaseTy    -> SolveError
  Unqual        :: Qualifier -> Type      -> SolveError
  QualSkolem    :: Qualifier -> Name Type -> SolveError
  Unknown       :: SolveError
  deriving Show

instance Monoid SolveError where
  mempty = Unknown
  e `mappend` _ = e

-- | Convert 'Nothing' into the given error.
maybeError :: MonadError e m => e -> Maybe a -> m a
maybeError e Nothing  = throwError e
maybeError _ (Just a) = return a

--------------------------------------------------
-- Solver monad

type SolveM a = FreshMT (Except SolveError) a

runSolveM :: SolveM a -> Either SolveError a
runSolveM = runExcept . runFreshMT

liftExcept :: MonadError e m => Except e a -> m a
liftExcept = either throwError return . runExcept

reifyExcept :: MonadError e m => m a -> m (Either e a)
reifyExcept m = (Right <$> m) `catchError` (return . Left)

filterExcept :: MonadError e m => [m a] -> m [a]
filterExcept ms = do
  es <- sequence . map reifyExcept $ ms
  case partitionEithers es of
    ((e:_), []) -> throwError e
    (_, as)     -> return as

--------------------------------------------------
-- Simple constraints and qualifier maps

data SimpleConstraint where
  (:<:) :: Type -> Type -> SimpleConstraint
  (:=:) :: Type -> Type -> SimpleConstraint
  deriving (Show, Eq, Ord, Generic)

instance Alpha SimpleConstraint

instance Subst Type SimpleConstraint

newtype SortMap = SM { unSM :: Map (Name Type) Sort }
  deriving (Show)

instance Semigroup SortMap where
  SM sm1 <> SM sm2 = SM (M.unionWith (<>) sm1 sm2)

instance Monoid SortMap where
  mempty  = SM M.empty
  mappend = (<>)

getSort :: SortMap -> Name Type -> Sort
getSort (SM sm) v = fromMaybe topSort (M.lookup v sm)

--------------------------------------------------
-- Simplifier types

-- Uses TH to generate lenses so it has to go here before other stuff.

-- The simplification stage maintains a mutable state consisting of
-- the current qualifier map (containing wanted qualifiers for type variables),
-- the list of remaining SimpleConstraints, and the current substitution.
data SimplifyState = SS
  { _ssSortMap     :: SortMap
  , _ssConstraints :: [SimpleConstraint]
  , _ssSubst       :: S
  , _ssSeen        :: Set SimpleConstraint
  }

makeLenses ''SimplifyState

lkup :: (Ord k, Show k, Show (Map k a)) => String -> Map k a -> k -> a
lkup msg m k = fromMaybe (error errMsg) (M.lookup k m)
  where
    errMsg = unlines
      [ "Key lookup error:"
      , "  Key = " ++ show k
      , "  Map = " ++ show m
      , "  Location: " ++ msg
      ]

--------------------------------------------------
-- Top-level solver algorithm

solveConstraint :: M.Map String Type -> Constraint -> SolveM S
solveConstraint tyDefns c = do

  -- Step 1. Open foralls (instantiating with skolem variables) and
  -- collect wanted qualifiers.  Should result in just a list of
  -- equational and subtyping constraints in addition to qualifiers.

  traceShowM c

  traceM "------------------------------"
  traceM "Decomposing constraints..."

  qcList <- decomposeConstraint c

  msum (map (uncurry (solveConstraintChoice tyDefns)) qcList)

solveConstraintChoice :: M.Map String Type -> SortMap -> [SimpleConstraint] -> SolveM S
solveConstraintChoice tyDefns quals cs = do

  traceM (show quals)
  traceM (show cs)

  -- Step 2. Check for weak unification to ensure termination. (a la
  -- Traytel et al).

  let toEqn (t1 :<: t2) = (t1,t2)
      toEqn (t1 :=: t2) = (t1,t2)
  _ <- maybeError NoWeakUnifier $ weakUnify tyDefns (map toEqn cs)

  -- Step 3. Simplify constraints, resulting in a set of atomic
  -- subtyping constraints.  Also simplify/update qualifier set
  -- accordingly.

  traceM "------------------------------"
  traceM "Running simplifier..."

  (sm, atoms, theta_simp) <- liftExcept (simplify tyDefns quals cs)

  traceM (show sm)
  traceM (show atoms)
  traceM (show theta_simp)

  -- Step 4. Turn the atomic constraints into a directed constraint
  -- graph.

  traceM "------------------------------"
  traceM "Generating constraint graph..."
  let g = mkConstraintGraph atoms

  traceShowM g

  -- Step 5.
  -- Check for any weakly connected components containing more
  -- than one skolem, or a skolem and a base type; such components are
  -- not allowed.  Other WCCs with a single skolem simply unify to
  -- that skolem.

  traceM "------------------------------"
  traceM "Checking WCCs for skolems..."

  (g', theta_skolem) <- liftExcept (checkSkolems tyDefns sm g)
  traceShowM theta_skolem

  -- We don't need to ensure that theta_skolem respects sorts since
  -- checkSkolems will only unify skolem vars with unsorted variables.


  -- Step 6. Eliminate cycles from the graph, turning each strongly
  -- connected component into a single node, unifying all the atoms in
  -- each component.

  traceM "------------------------------"
  traceM "Collapsing SCCs..."

  (g'', theta_cyc) <- liftExcept (elimCycles tyDefns g')

  -- Check that the resulting substitution respects sorts...
  when (not $ all (\(x,TyAtom (ABase ty)) -> hasSort ty (getSort sm x)) theta_cyc)
    $ throwError NoUnify

  traceShowM g''
  traceShowM theta_cyc

  -- Steps 7 & 8: solve the graph, iteratively finding satisfying
  -- assignments for each type variable based on its successor and
  -- predecessor base types in the graph; then unify all the type
  -- variables in any remaining weakly connected components.

  traceM "------------------------------"
  traceM "Solving for type variables..."

  theta_sol       <- solveGraph sm g''
  traceShowM theta_sol

  traceM "------------------------------"
  traceM "Composing final substitution..."

  let theta_final = (theta_sol @@ theta_cyc @@ theta_skolem @@ theta_simp)
  traceShowM theta_final

  return theta_final


--------------------------------------------------
-- Step 1. Constraint decomposition.

decomposeConstraint :: Constraint -> SolveM [(SortMap, [SimpleConstraint])]
decomposeConstraint (CSub t1 t2) = return [(mempty, [t1 :<: t2])]
decomposeConstraint (CEq  t1 t2) = return [(mempty, [t1 :=: t2])]
decomposeConstraint (CQual q ty) = ((:[]) . (, [])) <$> decomposeQual ty q
decomposeConstraint (CAnd cs)    = (map mconcat . sequence) <$> mapM decomposeConstraint cs
decomposeConstraint CTrue        = return [mempty]
decomposeConstraint (CAll ty)    = do
  (vars, c) <- unbind ty
  let c' = substs (mkSkolems vars) c
  decomposeConstraint c'

  where
    mkSkolems :: [Name Type] -> [(Name Type, Type)]
    mkSkolems = map (id &&& Skolem)
decomposeConstraint (COr cs)     = concat <$> filterExcept (map decomposeConstraint cs)

decomposeQual :: Type -> Qualifier -> SolveM SortMap
decomposeQual (TyAtom a) q       = checkQual q a
decomposeQual ty@(TyDef _) q     = throwError $ Unqual q ty   -- XXX FOR NOW!
decomposeQual ty@(TyCon c tys) q
  = case (M.lookup c >=> M.lookup q) qualRules of
      Nothing -> throwError $ Unqual q ty
      Just qs -> mconcat <$> zipWithM (maybe (return mempty) . decomposeQual) tys qs

checkQual :: Qualifier -> Atom -> SolveM SortMap
checkQual q (AVar (U v)) = return . SM $ M.singleton v (S.singleton q)
checkQual q (AVar (S v)) = throwError $ QualSkolem q v
checkQual q (ABase bty)  =
  case hasQual bty q of
    True  -> return mempty
    False -> throwError $ UnqualBase q bty

--------------------------------------------------
-- Step 3. Constraint simplification.

-- SimplifyM a = StateT SimplifyState SolveM a
--
--   (we can't literally write that as the definition since SolveM is
--   a type synonym and hence must be fully applied)

type SimplifyM a = StateT SimplifyState (FreshMT (Except SolveError)) a

-- | This step does unification of equality constraints, as well as
--   structural decomposition of subtyping constraints.  For example,
--   if we have a constraint (x -> y) <: (z -> Int), then we can
--   decompose it into two constraints, (z <: x) and (y <: Int); if we
--   have a constraint v <: (a,b), then we substitute v ↦ (x,y) (where
--   x and y are fresh type variables) and continue; and so on.
--
--   After this step, the remaining constraints will all be atomic
--   constraints, that is, only of the form (v1 <: v2), (v <: b), or
--   (b <: v), where v is a type variable and b is a base type.

simplify :: M.Map String Type -> SortMap -> [SimpleConstraint] -> Except SolveError (SortMap, [(Atom, Atom)], S)
simplify tyDefns origSM cs
  = (\(SS sm' cs' s' _) -> (sm', map extractAtoms cs', s'))
  <$> contFreshMT (execStateT simplify' (SS origSM cs idS S.empty)) n
  where

    fvNums :: Alpha a => [a] -> [Integer]
    fvNums = map (name2Integer :: Name Type -> Integer) . toListOf fv

    -- Find first unused integer in constraint free vars and sort map
    -- domain, and use it to start the fresh var generation, so we don't
    -- generate any "fresh" names that interfere with existing names
    n1 = maximum0 . fvNums $ cs
    n = succ . maximum . (n1:) . fvNums . M.keys . unSM $ origSM

    maximum0 [] = 0
    maximum0 xs = maximum xs

    -- Extract the type atoms from an atomic constraint.
    extractAtoms :: SimpleConstraint -> (Atom, Atom)
    extractAtoms (TyAtom a1 :<: TyAtom a2) = (a1, a2)
    extractAtoms c = error $ "Impossible: simplify left non-atomic or non-subtype constraint " ++ show c

    -- Iterate picking one simplifiable constraint and simplifying it
    -- until none are left.
    simplify' :: SimplifyM ()
    simplify' = do
      -- q <- gets fst
      -- traceM (pretty q)
      -- traceM ""

      mc <- pickSimplifiable
      case mc of
        Nothing -> return ()
        Just s  -> do

          traceM (show s)
          traceM "---------------------------------------"

          simplifyOne s
          simplify'

    -- Pick out one simplifiable constraint, removing it from the list
    -- of constraints in the state.  Return Nothing if no more
    -- constraints can be simplified.
    pickSimplifiable :: SimplifyM (Maybe SimpleConstraint)
    pickSimplifiable = do
      curCs <- use ssConstraints
      case pick simplifiable curCs of
        Nothing     -> return Nothing
        Just (a,as) -> do
          ssConstraints .= as
          return (Just a)

    -- Pick the first element from a list satisfying the given
    -- predicate, returning the element and the list with the element
    -- removed.
    pick :: (a -> Bool) -> [a] -> Maybe (a,[a])
    pick _ [] = Nothing
    pick p (a:as)
      | p a       = Just (a,as)
      | otherwise = second (a:) <$> pick p as

    -- Check if a constraint can be simplified.  An equality
    -- constraint can always be "simplified" via unification.  A
    -- subtyping constraint can be simplified if either it involves a
    -- type constructor (in which case we can decompose it), or if it
    -- involves two base types (in which case it can be removed if the
    -- relationship holds).
    simplifiable :: SimpleConstraint -> Bool
    simplifiable (_ :=: _)                               = True
    simplifiable (TyCon {} :<: TyCon {})                 = True
    simplifiable (TyVar {} :<: TyCon {})                 = True
    simplifiable (TyCon {} :<: TyVar  {})                = True
    simplifiable (TyDef {} :<: _)                        = True
    simplifiable (_ :<: TyDef {})                        = True
    simplifiable (TyAtom (ABase _) :<: TyAtom (ABase _)) = True

    simplifiable _                                       = False

    -- Simplify the given simplifiable constraint.  XXX say something about recursion
    simplifyOne :: SimpleConstraint -> SimplifyM ()
    simplifyOne c = do
      seen <- use ssSeen
      case c `S.member` seen of
        True  -> return ()
        False -> do
          ssSeen %= S.insert c
          simplifyOne' c

    -- XXX comment me
    simplifyOne' :: SimpleConstraint -> SimplifyM ()

    -- If we have an equality constraint, run unification on it.  The
    -- resulting substitution is applied to the remaining constraints
    -- as well as prepended to the current substitution.

    -- XXX need to expand TyDef here!
    simplifyOne' (ty1 :=: ty2) =
      case unify tyDefns [(ty1, ty2)] of
        Nothing -> throwError NoUnify
        Just s' -> extendSubst s'

    simplifyOne' (TyDef t :<: ty2) =
      case M.lookup t tyDefns of
        Nothing  -> throwError $ Unknown
        Just ty1 -> ssConstraints %= ((ty1 :<: ty2) :)

    simplifyOne' (ty1 :<: TyDef t) =
      case M.lookup t tyDefns of
        Nothing  -> throwError $ Unknown
        Just ty2 -> ssConstraints %= ((ty1 :<: ty2) :)

    -- Given a subtyping constraint between two type constructors,
    -- decompose it if the constructors are the same (or fail if they
    -- aren't), taking into account the variance of each argument to
    -- the constructor.
    simplifyOne' (TyCon c1 tys1 :<: TyCon c2 tys2)
      | c1 /= c2  = throwError NoUnify
      | otherwise =
          ssConstraints %= (zipWith3 variance (arity c1) tys1 tys2 ++)

    -- Given a subtyping constraint between a variable and a type
    -- constructor, expand the variable into the same constructor
    -- applied to fresh type variables.
    simplifyOne' con@(TyVar a   :<: TyCon c _) = expandStruct a c con
    simplifyOne' con@(TyCon c _ :<: TyVar a  ) = expandStruct a c con

    -- Given a subtyping constraint between two base types, just check
    -- whether the first is indeed a subtype of the second.  (Note
    -- that we only pattern match here on type atoms, which could
    -- include variables, but this will only ever get called if
    -- 'simplifiable' was true, which checks that both are base
    -- types.)
    simplifyOne' (TyAtom (ABase b1) :<: TyAtom (ABase b2)) = do
      case isSubB b1 b2 of
        True  -> return ()
        False -> throwError NoUnify

    expandStruct :: Name Type -> Con -> SimpleConstraint -> SimplifyM ()
    expandStruct a c con = do
      as <- mapM (const (TyVar <$> fresh (string2Name "a"))) (arity c)
      let s' = a |-> TyCon c as
      ssConstraints %= (con:)
      extendSubst s'

    -- 1. compose s' with current subst
    -- 2. apply s' to constraints
    -- 3. apply s' to qualifier map and decompose
    extendSubst :: S -> SimplifyM ()
    extendSubst s' = do
      ssSubst %= (s'@@)
      ssConstraints %= substs s'
      substSortMap s'

    substSortMap :: S -> SimplifyM ()
    substSortMap s' = do
      SM sm <- use ssSortMap

      -- 1. Get quals for each var in domain of s' and match them with
      -- the types being substituted for those vars.

      let tySorts :: [(Type, Sort)]
          tySorts = catMaybes . map (traverse (flip M.lookup sm) . swap) $ s'

          tyQualList :: [(Type, Qualifier)]
          tyQualList = concatMap (sequenceA . second S.toList) $ tySorts

      -- 2. Decompose the resulting qualifier constraints

      SM sm' <- lift $ mconcat <$> mapM (uncurry decomposeQual) tyQualList

      -- 3. delete domain of s' from sm and merge in decomposed quals.
      --    Be sure to keep quals from before, via 'unionWith'!

      ssSortMap .= SM (M.unionWith S.union sm' (foldl' (flip M.delete) sm (map fst s')))

      -- The above works even when unifying two variables.  Say we have
      -- the SortMap
      --
      --   a |-> {add}
      --   b |-> {sub}
      --
      -- and we get back theta = [a |-> b].  The domain of theta
      -- consists solely of a, so we look up a in the SortMap and get
      -- {add}.  We therefore generate the constraint 'add (theta a)'
      -- = 'add b' which can't be decomposed at all, and hence yields
      -- the SortMap {b |-> {add}}.  We then delete a from the
      -- original SortMap and merge the result with the new SortMap,
      -- yielding {b |-> {sub,add}}.


    -- Create a subtyping constraint based on the variance of a type
    -- constructor argument position: in the usual order for
    -- covariant, and reversed for contravariant.
    variance Co     ty1 ty2 = ty1 :<: ty2
    variance Contra ty1 ty2 = ty2 :<: ty1

--------------------------------------------------
-- Step 4: Build constraint graph

-- | Given a list of atomic subtype constraints (each pair @(a1,a2)@
--   corresponds to the constraint @a1 <: a2@) build the corresponding
--   constraint graph.
mkConstraintGraph :: [(Atom, Atom)] -> Graph Atom
mkConstraintGraph cs = G.mkGraph nodes (S.fromList cs)
  where
    nodes = S.fromList $ cs ^.. traverse . each

--------------------------------------------------
-- Step 5: Check skolems

-- | Check for any weakly connected components containing more than
--   one skolem, or a skolem and a base type, or a skolem and any
--   variables with nontrivial sorts; such components are not allowed.
--   If there are any WCCs with a single skolem, no base types, and
--   only unsorted variables, just unify them all with the skolem and
--   remove those components.
checkSkolems :: Map String Type -> SortMap -> Graph Atom -> Except SolveError (Graph UAtom, S)
checkSkolems tyDefns (SM sm) graph = do
  let skolemWCCs :: [Set Atom]
      skolemWCCs = filter (any isSkolem) $ G.wcc graph

      ok wcc =  S.size (S.filter isSkolem wcc) <= 1
             && all (\case { ABase _ -> False
                           ; AVar (S _) -> True
                           ; AVar (U v) -> maybe True S.null (M.lookup v sm) })
                wcc

      (good, bad) = partition ok skolemWCCs

  when (not . null $ bad) $ throwError NoUnify

  -- take all good sets and
  --   (1) delete them from the graph
  --   (2) unify them all with the skolem
  unifyWCCs graph idS good

  where
    noSkolems (ABase b)    = Left b
    noSkolems (AVar (U v)) = Right v
    noSkolems (AVar (S v)) = error $ "Skolem " ++ show v ++ " remaining in noSkolems"

    unifyWCCs g s []     = return (G.map noSkolems g, s)
    unifyWCCs g s (u:us) = do
      traceM $ "Unifying " ++ show (u:us) ++ "..."

      let g' = foldl' (flip G.delete) g u

          ms' = unifyAtoms tyDefns (S.toList u)
      case ms' of
        Nothing -> throwError NoUnify
        Just s' -> unifyWCCs g' (atomToTypeSubst s' @@ s) us

--------------------------------------------------
-- Step 6: Eliminate cycles

-- | Eliminate cycles in the constraint set by collapsing each
--   strongly connected component to a single node, (unifying all the
--   types in the SCC). A strongly connected component is a maximal
--   set of nodes where every node is reachable from every other by a
--   directed path; since we are using directed edges to indicate a
--   subtyping constraint, this means every node must be a subtype of
--   every other, and the only way this can happen is if all are in
--   fact equal.
--
--   Of course, this step can fail if the types in a SCC are not
--   unifiable.  If it succeeds, it returns the collapsed graph (which
--   is now guaranteed to be acyclic, i.e. a DAG) and a substitution.
elimCycles :: Map String Type -> Graph UAtom -> Except SolveError (Graph UAtom, S)
elimCycles tyDefns g
  = maybeError NoUnify
  $ (G.map fst &&& (atomToTypeSubst . compose . S.map snd . G.nodes)) <$> g'
  where

    g' :: Maybe (Graph (UAtom, S' Atom))
    g' = G.sequenceGraph $ G.map unifySCC (G.condensation g)

    unifySCC :: Set UAtom -> Maybe (UAtom, S' Atom)
    unifySCC uatoms = case S.toList uatoms of
      []       -> error "Impossible! unifySCC on the empty set"
      as@(a:_) -> (flip substs a &&& id) <$> unifyAtoms tyDefns (map uatomToAtom as)

------------------------------------------------------------
-- Steps 7 and 8: Constraint resolution
------------------------------------------------------------

-- | Rels stores the set of base types and variables related to a
--   given variable in the constraint graph (either predecessors or
--   successors, but not both).
data Rels = Rels
  { baseRels :: Set BaseTy
  , varRels  :: Set (Name Type)
  }
  deriving (Show, Eq)

-- | A RelMap associates each variable to its sets of base type and
--   variable predecessors and successors in the constraint graph.
type RelMap = Map (Name Type, Dir) Rels

-- | Modify a @RelMap@ to record the fact that we have solved for a
--   type variable.  In particular, delete the variable from the
--   @RelMap@ as a key, and also update the relative sets of every
--   other variable to remove this variable and add the base type we
--   chose for it.
substRel :: Name Type -> BaseTy -> RelMap -> RelMap
substRel x ty
  = M.delete (x,SuperTy)
  . M.delete (x,SubTy)
  . M.map (\r@(Rels b v) -> if x `S.member` v then Rels (S.insert ty b) (S.delete x v) else r)

-- | Essentially dirtypesBySort sm rm dir t s x finds all the
--   dir-types (sub- or super-) of t which have sort s, relative to
--   the variables in x.  This is \overbar{T}_S^X (resp. \underbar...)
--   from Traytel et al.
dirtypesBySort :: SortMap -> RelMap -> Dir -> BaseTy -> Sort -> Set (Name Type) -> [BaseTy]
dirtypesBySort sm relMap dir t s x

    -- Keep only those supertypes t' of t
  = keep (dirtypes dir t) $ \t' ->
      -- which have the right sort, and such that
      hasSort t' s &&

      -- for all variables beta \in x,
      (forAll x $ \beta ->

       -- there is at least one type t'' which is a subtype of t'
       -- which would be a valid solution for beta, that is,
       exists (dirtypes (other dir) t') $ \t'' ->

          -- t'' has the sort beta is supposed to have, and
         (hasSort t'' (getSort sm beta)) &&

          -- t'' is a supertype of every base type predecessor of beta.
         (forAll (baseRels (lkup "dirtypesBySort, beta rel" relMap (beta, other dir))) $ \u ->
            isDirB dir t'' u
         )
      )

    -- The above comments are written assuming dir = Super; of course,
    -- if dir = Sub then just swap "super" and "sub" everywhere.

  where
    forAll, exists :: Foldable t => t a -> (a -> Bool) -> Bool
    forAll = flip all
    exists = flip any
    keep   = flip filter

-- | Sort-aware infimum or supremum.
limBySort :: SortMap -> RelMap -> Dir -> [BaseTy] -> Sort -> Set (Name Type) -> Maybe BaseTy
limBySort sm rm dir ts s x
  = (\is -> find (\lim -> all (\u -> isDirB dir u lim) is) is)
  . isects
  . map (\t -> dirtypesBySort sm rm dir t s x)
  $ ts
  where
    isects = foldr1 intersect

lubBySort, glbBySort :: SortMap -> RelMap -> [BaseTy] -> Sort -> Set (Name Type) -> Maybe BaseTy
lubBySort sm rm = limBySort sm rm SuperTy
glbBySort sm rm = limBySort sm rm SubTy

-- | From the constraint graph, build the sets of sub- and super- base
--   types of each type variable, as well as the sets of sub- and
--   supertype variables.  For each type variable x in turn, try to
--   find a common supertype of its base subtypes which is consistent
--   with the sort of x and with the sorts of all its sub-variables,
--   as well as symmetrically a common subtype of its supertypes, etc.
--   Assign x one of the two: if it has only successors, assign it
--   their inf; otherwise, assign it the sup of its predecessors.  If
--   it has both, we have a choice of whether to assign it the sup of
--   predecessors or inf of successors; both lead to a sound &
--   complete algorithm.  We choose to assign it the sup of its
--   predecessors in this case, since it seems nice to default to
--   "simpler" types lower down in the subtyping chain.
solveGraph :: SortMap -> Graph UAtom -> SolveM S
solveGraph sm g = (atomToTypeSubst . unifyWCC) <$> go topRelMap
  where
    unifyWCC :: S' BaseTy -> S' Atom
    unifyWCC s = concatMap mkEquateSubst wccVarGroups @@ (map (coerce *** ABase) s)
      where
        wccVarGroups :: [Set (Name Type)]
        wccVarGroups  = map (S.map getVar) . filter (all isRight) . substs s $ G.wcc g
        getVar (Right v) = v
        getVar (Left b)  = error
          $ "Impossible! Base type " ++ show b ++ " in solveGraph.getVar"

        mkEquateSubst :: Set (Name Type) -> S' Atom
        mkEquateSubst = (\(a:as) -> map (\v -> (coerce v, AVar (U a))) as) . S.toList

            -- After picking concrete base types for all the type
            -- variables we can, the only thing possibly remaining in
            -- the graph are components containing only type variables
            -- and no base types.  It is sound, and simplifies the
            -- generated types considerably, to simply unify any type
            -- variables which are related by subtyping constraints.
            -- That is, we collect all the type variables in each
            -- weakly connected component and unify them.
            --
            -- As an example where this final step makes a difference,
            -- consider a term like @\x. (\y.y) x@.  A fresh type
            -- variable is generated for the type of @x@, and another
            -- for the type of @y@; the application of @(\y.y)@ to @x@
            -- induces a subtyping constraint between the two type
            -- variables.  The most general type would be something
            -- like @forall a b. (a <: b) => a -> b@, but we want to
            -- avoid generating unnecessary subtyping constraints (the
            -- type system might not even support subtyping qualifiers
            -- like this).  Instead, we unify the two type variables
            -- and the resulting type is @forall a. a -> a@.

    -- Get the successor and predecessor sets for all the type variables.
    topRelMap :: RelMap
    topRelMap
      = M.map (uncurry Rels . (S.fromAscList *** S.fromAscList) . partitionEithers . S.toList)
      $ M.mapKeys (,SuperTy) subMap `M.union` M.mapKeys (,SubTy) superMap

    subMap, superMap :: Map (Name Type) (Set UAtom)
    (subMap, superMap) = (onlyVars *** onlyVars) $ G.cessors g

    onlyVars :: Map UAtom (Set UAtom) -> Map (Name Type) (Set UAtom)
    onlyVars = M.mapKeys (\(Right n) -> n) . M.filterWithKey (\a _ -> isRight a)

    go :: RelMap -> SolveM (S' BaseTy)
    go relMap = case as of

      -- No variables left that have base type constraints.
      []    -> return idS

      -- Solve one variable at a time.  See below.
      (a:_) ->

        case solveVar a of
          Nothing       -> do
            traceM $ "Couldn't solve for " ++ show a
            throwError NoUnify

          -- If we solved for a, delete it from the maps, apply the
          -- resulting substitution to the remainder (updating the
          -- relMap appropriately), and recurse.  The substitution we
          -- want will be the composition of the substitution for a
          -- with the substitution generated by the recursive call.
          --
          -- Note we don't need to delete a from the SortMap; we never
          -- use the set of keys from the SortMap for anything
          -- (indeed, some variables might not be keys if they have an
          -- empty sort), so it doesn't matter if old variables hang
          -- around in it.
          Just s ->
            (@@ s) <$> go (substRel a (fromJust $ P.lookup (coerce a) s) $ relMap)

      where
        -- NOTE we can't solve a bunch in parallel!  Might end up
        -- assigning them conflicting solutions if some depend on
        -- others.  For example, consider the situation
        --
        --            Z
        --            |
        --            a3
        --           /  \
        --          a1   N
        --
        -- If we try to solve in parallel we will end up assigning a1
        -- -> Z (since it only has base types as an upper bound) and
        -- a3 -> N (since it has both upper and lower bounds, and by
        -- default we pick the lower bound), but this is wrong since
        -- we should have a1 < a3.
        --
        -- If instead we solve them one at a time, we could e.g. first
        -- solve a1 -> Z, and then we would find a3 -> Z as well.
        -- Alternately, if we first solve a3 -> N then we will have a1
        -- -> N as well.  Both are acceptable.
        --
        -- In fact, this exact graph comes from (^x.x+1) which was
        -- erroneously being inferred to have type Z -> N when I first
        -- wrote the code.

        -- Get only the variables we can solve on this pass, which
        -- have base types in their predecessor or successor set.  If
        -- there are no such variables, then start picking any
        -- remaining variables with a sort and pick types for them
        -- (disco doesn't have qualified polymorphism so we can't just
        -- leave them).
        asBase
          = map fst
          . filter (not . S.null . baseRels . lkup "solveGraph.go.as" relMap)
          $ M.keys relMap
        as = case asBase of
          [] -> filter ((/= topSort) . getSort sm) . map fst $ M.keys relMap
          _  -> asBase

        -- Solve for a variable, failing if it has no solution, otherwise returning
        -- a substitution for it.
        solveVar :: Name Type -> Maybe (S' BaseTy)
        solveVar v =
          case ((v,SuperTy), (v,SubTy)) & over both (S.toList . baseRels . (lkup "solveGraph.solveVar" relMap)) of
            -- No sub- or supertypes; the only way this can happen is
            -- if it has a nontrivial sort.  We just pick a type that
            -- inhabits the sort.
            ([], []) ->
              Just (coerce v |-> pickSortBaseTy (getSort sm v))

            -- Only supertypes.  Just assign a to their inf, if one exists.
            (bsupers, []) ->
              -- trace (show v ++ " has only supertypes (" ++ show bsupers ++ ")") $
              (coerce v |->) <$> glbBySort sm relMap bsupers (getSort sm v)
                (varRels (lkup "solveVar bsupers, rels" relMap (v,SuperTy)))

            -- Only subtypes.  Just assign a to their sup.
            ([], bsubs)   ->
              -- trace (show v ++ " has only subtypes (" ++ show bsubs ++ ")") $
              -- trace ("sortmap: " ++ show sm) $
              -- trace ("relmap: " ++ show relMap) $
              -- trace ("sort for " ++ show v ++ ": " ++ show (getSort sm v)) $
              -- trace ("relvars: " ++ show (varRels (relMap ! (v,Sub)))) $
              (coerce v |->) <$> lubBySort sm relMap bsubs (getSort sm v)
                (varRels (lkup "solveVar bsubs, rels" relMap (v,SubTy)))

            -- Both successors and predecessors.  Both must have a
            -- valid bound, and the bounds must not overlap.  Assign a
            -- to the sup of its predecessors.
            (bsupers, bsubs) -> do
              ub <- glbBySort sm relMap bsupers (getSort sm v)
                      (varRels (relMap ! (v,SuperTy)))
              lb <- lubBySort sm relMap bsubs   (getSort sm v)
                      (varRels (relMap ! (v,SubTy)))
              case isSubB lb ub of
                True  -> Just (coerce v |-> lb)
                False -> Nothing
