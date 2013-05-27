%
% (c) The University of Glasgow 2006
%

FamInstEnv: Type checked family instance declarations

\begin{code}
module FamInstEnv (
        Branched, Unbranched,

        FamInst(..), FamFlavor(..), FamInstBranch(..), 
        FamInstSpace(..), BranchFlag(..),

        famInstAxiom, famInstBranchRoughMatch,
        famInstsRepTyCons, famInstNthBranch, famInstSingleBranch,
        famInstBranchLHS, famInstBranches, 
        toBranchedFamInst, toUnbranchedFamInst,
        famInstTyCon, famInstRepTyCon_maybe, dataFamInstRepTyCon, 
        pprFamInst, pprFamInsts, 
        pprFamFlavor, 
        mkImportedFamInst, 

        FamInstEnv, FamInstEnvs,
        emptyFamInstEnvs, emptyFamInstEnv, famInstEnvElts, familyInstances,
        extendFamInstEnvList, extendFamInstEnv, deleteFromFamInstEnv,
        identicalFamInst, orphNamesOfFamInst,

        FamInstMatch(..),
        lookupFamInstEnv, lookupFamInstEnvConflicts, lookupFamInstEnvConflicts',
        
        isDominatedBy,

        -- Normalisation
        topNormaliseType, normaliseType, normaliseTcApp
    ) where

#include "HsVersions.h"

import TcType ( orphNamesOfTypes )
import InstEnv
import Unify
import Type
import Coercion hiding ( substTy )
import TypeRep
import TyCon
import CoAxiom
import VarSet
import VarEnv
import Name
import NameSet
import UniqFM
import Outputable
import Maybes
import Util
import FastString
\end{code}


%************************************************************************
%*                                                                      *
           Type checked family instance heads
%*                                                                      *
%************************************************************************

Note [FamInsts and CoAxioms]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
* CoAxioms and FamInsts are just like
  DFunIds  and ClsInsts

* A CoAxiom is a System-FC thing: it can relate any two types

* A FamInst is a Haskell source-language thing, corresponding
  to a type/data family instance declaration.
    - The FamInst contains a CoAxiom, which is the evidence
      for the instance

    - The LHSs of the CoAxiom branches are always of form
      F ty1 .. tyn where F is a type family

* A FamInstBranch corresponds to a CoAxBranch -- it represents
  one alternative in a branched family instance. We could theoretically
  not have FamInstBranches and just use the CoAxBranches within
  the CoAxiom stored in the FamInst, but for one problem: we want to
  cache the "rough match" top-level tycon names for quick matching.
  This data is not stored in a CoAxBranch, so we use FamInstBranches
  instead.

Note [fi_branched field]
~~~~~~~~~~~~~~~~~~~~~~~~
A FamInst stores whether or not it was declared with "type instance where"
for two reasons: 
  1. for accurate pretty-printing; and 
  2. because confluent overlap is disallowed between branches 
     declared in groups. 
Note that this "branched-ness" is properly associated with the FamInst,
which thinks about overlap, and not in the CoAxiom, which blindly
assumes that it is part of a consistent axiom set.

A "branched" instance with fi_branched=Branched can have just one branch, however.

Note [Why we need fib_rhs]
~~~~~~~~~~~~~~~~~~~~~~~~~~
It may at first seem unnecessary to store the right-hand side of an equation
in a FamInstBranch. After all, FamInstBranches are used only for matching a
family application; the underlying CoAxiom is used to perform the actual
simplification.

However, we do need to know the rhs field during conflict checking to support
confluent overlap. When two unbranched instances have overlapping left-hand
sides, we check if the right-hand sides are coincident in the region of overlap.
This check requires fib_rhs. See lookupFamInstEnvConflicts.

Note [Instance type spaces]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
A branched instance declaration may optionally include a type space -- that is,
a space of types in which all branches sit. This type space is what is used during
conflict checking. The type space *must* have a linear pattern. Having all
(potentially non-linear) branches sit within one (linear) space is necessary to
ensure consistency of the axiom set.

If a type space is not included, it is assumed to be the trivial one -- that is,
encompassing all possible applications of the type family.

Unbranched instances cannot contain an explicit type space, because the type space
is assumed to be identical to the left-hand side of the instance (which must be
linear). It is therefore an invariant of FamInst that all unbranched instances
have an appropriate type space included.

\begin{code}
data FamInst br -- See Note [FamInsts and CoAxioms], Note [Branched axioms] in CoAxiom
  = FamInst { fi_axiom    :: CoAxiom br      -- The new coercion axiom introduced
                                             -- by this family instance
            , fi_flavor   :: FamFlavor
            , fi_branched :: BranchFlag      -- See Note [fi_branched field]
            , fi_space    :: FamInstSpace    -- See Note [Instance type spaces]


            -- Everything below here is a redundant,
            -- cached version of the two things above,
            -- except that the TyVars are freshened in the FamInstBranches
            , fi_branches :: BranchList FamInstBranch br
                                             -- Haskell-source-language view of 
                                             -- a CoAxBranch
            , fi_fam      :: Name            -- Family name
                -- INVARIANT: fi_fam = name of fi_axiom.co_ax_tc
            }

-- See Note [Instance type spaces]
data FamInstSpace
  = NoFamInstSpace
  | FamInstSpace { fis_tvs :: [TyVar]  -- tyvars used in...
                 , fis_tys :: [Type]   -- ...these type patterns
                 , fis_tcs :: [Maybe Name] -- rough match fields
                 , fis_loc :: SrcSpan
                 }

data FamInstBranch
  = FamInstBranch
    { fib_tvs    :: [TyVar]      -- Bound type variables
                                 -- Like ClsInsts, these variables are always
                                 -- fresh. See Note [Template tyvars are fresh]
                                 -- in InstEnv
    , fib_lhs    :: [Type]       -- type patterns
    , fib_rhs    :: Type         -- RHS of family instance
                                 -- See Note [Why we need fib_rhs]
    , fib_tcs    :: [Maybe Name] -- used for "rough matching" during typechecking
                                 -- see Note [Rough-match field] in InstEnv
    }

data FamFlavor 
  = SynFamilyInst         -- A synonym family
  | DataFamilyInst TyCon  -- A data family, with its representation TyCon
\end{code}


\begin{code}
isFamInstSpace :: FamInstSpace -> Bool
isFamInstSpace (FamInstSpace {}) = True
isFamInstSpace NoFamInstSpace    = False

-- Obtain the axiom of a family instance
famInstAxiom :: FamInst br -> CoAxiom br
famInstAxiom = fi_axiom

famInstTyCon :: FamInst br -> TyCon
famInstTyCon = co_ax_tc . fi_axiom

famInstNthBranch :: FamInst br -> Int -> FamInstBranch
famInstNthBranch (FamInst { fi_branches = branches }) index
  = ASSERT( 0 <= index && index < (length $ fromBranchList branches) )
    brListNth branches index 

famInstSingleBranch :: FamInst Unbranched -> FamInstBranch
famInstSingleBranch (FamInst { fi_branches = FirstBranch branch }) = branch

toBranchedFamInst :: FamInst br -> FamInst Branched
toBranchedFamInst (FamInst ax flav grp branches fam)
  = FamInst (toBranchedAxiom ax) flav grp (toBranchedList branches) fam

toUnbranchedFamInst :: FamInst br -> FamInst Unbranched
toUnbranchedFamInst (FamInst ax flav grp branches fam)
  = FamInst (toUnbranchedAxiom ax) flav grp (toUnbranchedList branches) fam

famInstBranches :: FamInst br -> BranchList FamInstBranch br
famInstBranches = fi_branches

famInstBranchLHS :: FamInstBranch -> [Type]
famInstBranchLHS = fib_lhs

famInstBranchRoughMatch :: FamInstBranch -> [Maybe Name]
famInstBranchRoughMatch = fib_tcs

-- Return the representation TyCons introduced by data family instances, if any
famInstsRepTyCons :: [FamInst br] -> [TyCon]
famInstsRepTyCons fis = [tc | FamInst { fi_flavor = DataFamilyInst tc } <- fis]

-- Extracts the TyCon for this *data* (or newtype) instance
famInstRepTyCon_maybe :: FamInst br -> Maybe TyCon
famInstRepTyCon_maybe fi
  = case fi_flavor fi of
       DataFamilyInst tycon -> Just tycon
       SynFamilyInst        -> Nothing

dataFamInstRepTyCon :: FamInst br -> TyCon
dataFamInstRepTyCon fi
  = case fi_flavor fi of
       DataFamilyInst tycon -> tycon
       SynFamilyInst        -> pprPanic "dataFamInstRepTyCon" (ppr fi)
\end{code}

%************************************************************************
%*                                                                      *
        Pretty printing
%*                                                                      *
%************************************************************************

\begin{code}
instance NamedThing (FamInst br) where
   getName = coAxiomName . fi_axiom

instance Outputable (FamInst br) where
   ppr = pprFamInst

-- Prints the FamInst as a family instance declaration
pprFamInst :: FamInst br -> SDoc
pprFamInst (FamInst { fi_branches = brs, fi_flavor = SynFamilyInst
                    , fi_branched = Branched, fi_axiom = axiom
                    , fi_space = space })
  = hang (ptext (sLit "type instance") <+> ppr_space <+> ptext (sLit "where"))
       2 (vcat [pprCoAxBranchHdr axiom i | i <- brListIndices brs])
  where ppr_space
          | Nothing <- space      = empty
          | Just (FamInstSpace { fis_tys = tys }) <- space
          = pprTypeApp (coAxiomTyCon axiom) tys

pprFamInst fi@(FamInst { fi_flavor = flavor
                       , fi_branched = Unbranched, fi_axiom = ax })
  = pprFamFlavor flavor <+> pp_instance
    <+> pprCoAxBranchHdr ax 0
  where
    -- For *associated* types, say "type T Int = blah" 
    -- For *top level* type instances, say "type instance T Int = blah"
    pp_instance 
      | isTyConAssoc (famInstTyCon fi) = empty
      | otherwise                      = ptext (sLit "instance")

pprFamInst _ = panic "pprFamInst"

pprFamFlavor :: FamFlavor -> SDoc
pprFamFlavor flavor
  = case flavor of
      SynFamilyInst        -> ptext (sLit "type")
      DataFamilyInst tycon
        | isDataTyCon     tycon -> ptext (sLit "data")
        | isNewTyCon      tycon -> ptext (sLit "newtype")
        | isAbstractTyCon tycon -> ptext (sLit "data")
        | otherwise             -> ptext (sLit "WEIRD") <+> ppr tycon

pprFamInsts :: [FamInst br] -> SDoc
pprFamInsts finsts = vcat (map pprFamInst finsts)
\end{code}

Note [Lazy axiom match]
~~~~~~~~~~~~~~~~~~~~~~~
It is Vitally Important that mkImportedFamInst is *lazy* in its axiom
parameter. The axiom is loaded lazily, via a forkM, in TcIface. Sometime
later, mkImportedFamInst is called using that axiom. However, the axiom
may itself depend on entities which are not yet loaded as of the time
of the mkImportedFamInst. Thus, if mkImportedFamInst eagerly looks at the
axiom, a dependency loop spontaneously appears and GHC hangs. The solution
is simply for mkImportedFamInst never, ever to look inside of the axiom
until everything else is good and ready to do so. We can assume that this
readiness has been achieved when some other code pulls on the axiom in the
FamInst. Thus, we pattern match on the axiom lazily (in the where clause,
not in the parameter list) and we assert the consistency of names there
also.

\begin{code}

-- Make a family instance representation from the information found in an
-- interface file.  In particular, we get the rough match info from the iface
-- (instead of computing it here).
mkImportedFamInst :: Name               -- Name of the family
                  -> BranchFlag
                  -> FamInstSpace       -- type space
                  -> [[Maybe Name]]     -- Rough match info, per branch
                  -> CoAxiom Branched   -- Axiom introduced
                  -> FamInst Branched   -- Resulting family instance
mkImportedFamInst fam branched space roughs axiom
  = FamInst {
      fi_fam      = fam,
      fi_axiom    = axiom,
      fi_space    = space,
      fi_flavor   = flavor,
      fi_branched = branched,
      fi_branches = branches }
  where
     -- Lazy match (See note [Lazy axiom match])
     CoAxiom { co_ax_branches = axBranches }
       = ASSERT( fam == tyConName (coAxiomTyCon axiom) )
         axiom

     branches = toBranchList $ map mk_imp_fam_inst_branch $ 
                (roughs `zipLazy` fromBranchList axBranches)
                -- Lazy zip (See note [Lazy axiom match])

     mk_imp_fam_inst_branch (mb_tcs, ~(CoAxBranch { cab_tvs = tvs
                                                  , cab_lhs = lhs
                                                  , cab_rhs = rhs }))
                -- Lazy match (See note [Lazy axiom match])
       = FamInstBranch { fib_tvs    = tvs
                       , fib_lhs    = lhs
                       , fib_rhs    = rhs
                       , fib_tcs    = mb_tcs }

         -- Derive the flavor for an imported FamInst rather disgustingly
         -- Maybe we should store it in the IfaceFamInst?
     flavor
       | FirstBranch (CoAxBranch { cab_rhs = rhs }) <- axBranches
       , Just (tc, _) <- splitTyConApp_maybe rhs
       , Just ax' <- tyConFamilyCoercion_maybe tc
       , (toBranchedAxiom ax') == axiom
       = DataFamilyInst tc

       | otherwise
       = SynFamilyInst

mkImportedFamInstSpace :: [TyVar]      -- quantified variables
                       -> [Type]       -- patterns
                       -> [Maybe Name] -- rough match fields
                       -> FamInstSpace
mkImportedFamInstSpace tvs tys tcs
  = FamInstSpace { fis_tvs = tvs
                 , fis_tys = tys
                 , fis_tcs = tcs
                 , fis_loc = noSrcSpan }
\end{code}


%************************************************************************
%*                                                                      *
                FamInstEnv
%*                                                                      *
%************************************************************************

Note [FamInstEnv]
~~~~~~~~~~~~~~~~~~~~~
A FamInstEnv maps a family name to the list of known instances for that family.

The same FamInstEnv includes both 'data family' and 'type family' instances.
Type families are reduced during type inference, but not data families;
the user explains when to use a data family instance by using contructors
and pattern matching.

Neverthless it is still useful to have data families in the FamInstEnv:

 - For finding overlaps and conflicts

 - For finding the representation type...see FamInstEnv.topNormaliseType
   and its call site in Simplify

 - In standalone deriving instance Eq (T [Int]) we need to find the
   representation type for T [Int]

\begin{code}
type FamInstEnv = UniqFM FamilyInstEnv  -- Maps a family to its instances
     -- See Note [FamInstEnv]

type FamInstEnvs = (FamInstEnv, FamInstEnv)
     -- External package inst-env, Home-package inst-env

newtype FamilyInstEnv
  = FamIE [FamInst Branched] -- The instances for a particular family, in any order

instance Outputable FamilyInstEnv where
  ppr (FamIE fs) = ptext (sLit "FamIE") <+> vcat (map ppr fs)

-- INVARIANTS:
--  * The fs_tvs are distinct in each FamInst
--      of a range value of the map (so we can safely unify them)

emptyFamInstEnvs :: (FamInstEnv, FamInstEnv)
emptyFamInstEnvs = (emptyFamInstEnv, emptyFamInstEnv)

emptyFamInstEnv :: FamInstEnv
emptyFamInstEnv = emptyUFM

famInstEnvElts :: FamInstEnv -> [FamInst Branched]
famInstEnvElts fi = [elt | FamIE elts <- eltsUFM fi, elt <- elts]

familyInstances :: (FamInstEnv, FamInstEnv) -> TyCon -> [FamInst Branched]
familyInstances (pkg_fie, home_fie) fam
  = get home_fie ++ get pkg_fie
  where
    get env = case lookupUFM env fam of
                Just (FamIE insts) -> insts
                Nothing            -> []

-- | Collects the names of the concrete types and type constructors that
-- make up the LHS of a type family instance. For instance,
-- given `type family Foo a b`:
--
-- `type instance Foo (F (G (H a))) b = ...` would yield [F,G,H]
--
-- Used in the implementation of ":info" in GHCi.
orphNamesOfFamInst :: FamInst Branched -> NameSet
orphNamesOfFamInst
    = orphNamesOfTypes . concat . brListMap cab_lhs . coAxiomBranches . fi_axiom

extendFamInstEnvList :: FamInstEnv -> [FamInst br] -> FamInstEnv
extendFamInstEnvList inst_env fis = foldl extendFamInstEnv inst_env fis

extendFamInstEnv :: FamInstEnv -> FamInst br -> FamInstEnv
extendFamInstEnv inst_env ins_item@(FamInst {fi_fam = cls_nm})
  = addToUFM_C add inst_env cls_nm (FamIE [ins_item_br])
  where
    ins_item_br = toBranchedFamInst ins_item
    add (FamIE items) _ = FamIE (ins_item_br:items)

deleteFromFamInstEnv :: FamInstEnv -> FamInst br -> FamInstEnv
deleteFromFamInstEnv inst_env fam_inst@(FamInst {fi_fam = fam_nm})
 = adjustUFM adjust inst_env fam_nm
 where
   adjust :: FamilyInstEnv -> FamilyInstEnv
   adjust (FamIE items) = FamIE (filterOut (identicalFamInst fam_inst) items)

identicalFamInst :: FamInst br1 -> FamInst br2 -> Bool
-- Same LHS, *and* the instance is defined in the same module
-- Used for overriding in GHCi
identicalFamInst (FamInst { fi_axiom = ax1, fi_space = sp1 })
                 (FamInst { fi_axiom = ax2, fi_space = sp2 })
  =  nameModule (coAxiomName ax1) == nameModule (coAxiomName ax2)
     && tc1 == tc2
     && brListLength brs1 == brListLength brs2
     && and (brListZipWith identical_ax_branch brs1 brs2)
     && identical_space sp1 sp2
  where tc1 = coAxiomTyCon ax1
        tc2 = coAxiomTyCon ax2
        brs1 = coAxiomBranches ax1
        brs2 = coAxiomBranches ax2
        identical_ax_branch br1 br2
          = length tvs1 == length tvs2
            && length lhs1 == length lhs2
            && and (zipWith (eqTypeX rn_env) lhs1 lhs2)
          where
            tvs1 = coAxBranchTyVars br1
            tvs2 = coAxBranchTyVars br2
            lhs1 = coAxBranchLHS br1
            lhs2 = coAxBranchLHS br2
            rn_env = rnBndrs2 (mkRnEnv2 emptyInScopeSet) tvs1 tvs2

        identical_space Nothing Nothing = True
        identical_space Nothing (Just sp) = identical_space (Just sp) Nothing
        identical_space (Just (FamInstSpace { fis_tcs = tcs })) Nothing
          = all isNothing tcs
        identical_space (Just (FamInstSpace { fis_tvs = tvs1
                                            , fis_tys = tys1 }))
                        (Just (FamInstSpace { fis_tvs = tvs2
                                            , fis_tys = tys2 }))
          = eqTypesX rn_env tys1 tys2
          where rn_env = rnBndrs2 (mkRnEnv2 emptyInScopeSet) tvs1 tvs2
                       
\end{code}

%************************************************************************
%*                                                                      *
                Looking up a family instance
%*                                                                      *
%************************************************************************

@lookupFamInstEnv@ looks up in a @FamInstEnv@, using a one-way match.
Multiple matches are only possible in case of type families (not data
families), and then, it doesn't matter which match we choose (as the
instances are guaranteed confluent).

We return the matching family instances and the type instance at which it
matches.  For example, if we lookup 'T [Int]' and have a family instance

  data instance T [a] = ..

desugared to

  data :R42T a = ..
  coe :Co:R42T a :: T [a] ~ :R42T a

we return the matching instance '(FamInst{.., fi_tycon = :R42T}, Int)'.

Note [Branched instance checking]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Consider the following:

type instance where
  F Int = Bool
  F a   = Int

g :: Show a => a -> F a
g x = length (show x)

Should that type-check? No. We need to allow for the possibility that 'a'
might be Int and therefore 'F a' should be Bool. We can simplify 'F a' to Int
only when we can be sure that 'a' is not Int.

To achieve this, after we see that a branch does not match, we must check to
see if it is *surely apart* from the target. (See [Apartness] in
types/Unify.lhs.) This is similar to what happens with class instance
selection, when we need to guarantee that there is only a match and no
unifiers. The exact algorithm is different here because the the
potentially-overlapping group is closed.

As another example, consider this:

type family G x
type instance where
  G Int = Bool
  G a   = Double

type family H y
-- no instances

Now, we want to simplify (G (H Char)). We can't, because (H Char) might later
simplify to be Int. So, (G (H Char)) is stuck, for now.

Note [Early failure optimisation for branched instances]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
As we're searching through the instances for a match, it is possible that we
find a branch within an instance that matches, but a previous branch is not
surely apart from the target application. In this case, we can abort the
search, because any other instance that matches will necessarily overlap with
the instance we're currently searching. Because overlap among branched
instances is disallowed, we know that that no such other instance exists.

Note [Confluence checking within branched instances]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
GHC allows type family instances to have overlapping patterns as long as the
right-hand sides are coincident in the region of overlap. Can we extend this
notion of confluent overlap to branched instances? Not in any obvious way.

Consider this:

type instance where
  F Int = Int
  F a = a

Without confluence checking (in other words, as implemented), we cannot now
simplify an application of (F b) -- b might unify with Int later on, so this
application is stuck. However, it would seem easy to just check that, in the
region of overlap, (i.e. b |-> Int), the right-hand sides coincide, so we're
OK. The problem happens when we are simplifying an application (F (G a)),
where (G a) is stuck. What, now, is the region of overlap? We can't soundly
simplify (F (G a)) without knowing that the right-hand sides are confluent
in the region of overlap, but we also can't in any obvious way identify the
region of overlap. We don't want to do analysis on the instances of G, because
that is not sound in a world with open type families. (If G were known to be
closed, there might be a way forward here.) To find the region of overlap,
it is conceivable that we might convert (G a) to some fresh type variable and
then unify, but we must be careful to convert every (G a) to the same fresh
type variable. And then, what if there is an (H a) lying around? It all seems
rather subtle, error-prone, confusing, and probably won't help anyone. So,
we're not doing it.

So, why is this not a problem with non-branched confluent overlap? Because
we don't need to verify that an application is apart from anything. The
non-branched confluent overlap check happens when we add the instance to the
environment -- we're unifying among patterns, which cannot contain type family
applications. So, we're safe there and can continue supporting that feature.

\begin{code}
-- when matching a type family application, we get a FamInst,
-- a 0-based index of the branch that matched, and the list of types
-- the axiom should be applied to
data FamInstMatch = FamInstMatch { fim_instance :: FamInst Branched
                                 , fim_index    :: BranchIndex
                                 , fim_tys      :: [Type]
                                 }

instance Outputable FamInstMatch where
  ppr (FamInstMatch { fim_instance = inst
                    , fim_index    = ind
                    , fim_tys      = tys })
    = ptext (sLit "match with") <+> parens (ppr inst)
        <> brackets (ppr ind) <+> ppr tys

data ContSearch = KeepSearching
                | StopSearching

lookupFamInstEnv :: FamInstEnvs
                 -> TyCon -> [Type]          -- What we are looking for
                 -> [FamInstMatch]           -- Successful matches
-- Precondition: the tycon is saturated (or over-saturated)
lookupFamInstEnv (pkg_ie, home_ie) fam_tc tys
  = lookupFamInstEnv' pkg_ie  fam_tc tys ++
    lookupFamInstEnv' home_ie fam_tc tys

lookupFamInstEnv' :: FamInstEnvs
                  -> TyCon -> [Type]          -- What we are looking for
                  -> [FamInstMatch]           -- Successful matches
lookupFamInstEnv' ie fam tys
  | isFamilyTyCon fam
  , Just (FamIE insts) <- lookupUFM ie fam
  = ASSERT2( n_tys >= arity, ppr fam <+> ppr tys ) 
    if arity < n_tys then    -- Family type applications must be saturated
                             -- See Note [Over-saturated matches]
        map wrap_extra_tys (find (take arity tys) insts)
    else
        find tys insts    -- The common case

  | otherwise = []
  where
    arity = tyConArity fam
    n_tys = length tys
    extra_tys = drop arity tys
    wrap_extra_tys fim@(FamInstMatch { fim_tys = match_tys })
      = fim { fim_tys = match_tys ++ extra_tys }

find :: [Type] -> [FamInst Branched] -> [FamInstMatch]
find _ [] = []
find match_tys (inst@(FamInst { fi_branches = branches }) : rest)
  = case findBranch [] (fromBranchList branches) 0 of
      (Just match, StopSearching) -> [match]
      (Just match, KeepSearching) -> match : find match_tys rest
      (Nothing,    StopSearching) -> []
      (Nothing,    KeepSearching) -> find match_tys rest
  where
    rough_tcs = roughMatchTcs match_tys

    findBranch :: [FamInstBranch]  -- still looking through these
               -> BranchIndex      -- index of the first of the "still looking" list
               -> (Maybe FamInstMatch, ContSearch)
    findBranch [] _ = (Nothing, KeepSearching)
    findBranch (branch@(FamInstBranch { fib_tvs = tvs
                                      , fib_lhs = tpl_tys
                                      , fib_tcs = mb_tcs }) : rest) ind
      | instanceCantMatch rough_tcs mb_tcs
      = findBranch rest (ind+1)
      | otherwise
      = ASSERT( tyVarsOfTypes match_tys `disjointVarSet` mkVarSet tpl_tvs )
        case tcMatchTys tpl_tvs tpl_tys match_tys of
          Just subst
            -> let match = FamInstMatch { fim_instance = inst
                                        , fim_index    = ind
                                        , fim_tys      = substTyVars subst tvs } in
               (Just match, KeepSearching)

          Nothing
            -- See [Branched instance checking]
            | SurelyApart <- tcApartTys instanceBindFun tpl_tys match_tys
            -> findBranch rest (ind+1)
            | otherwise
            -- in this case, the branch did not match, but it's also not surely apart
            -- we won't be able to make progress here, so give up
            -- see Note [Early failure optimisation for branched instances]
            -> (Nothing, StopSearching)

      where tpl_tvs = mkVarSet tvs

-- E.g. when we are about to add
--    f : type instance F [a] = a->a
-- we do (lookupFamInstEnvConflicts f [b])
-- to find conflicting matches
lookupFamInstEnvConflicts :: FamInstEnvs
                          -> FamInst br            -- the putative new instance
                          -> [FamInst Branched]    -- Conflicting instances
lookupFamInstEnvConflicts (pkg_ie, home_ie) fi
  = lookupFamInstEnvConflicts' pkg_ie  fi ++
    lookupFamInstEnvConflicts' home_ie fi

lookupFamInstEnvConflicts' :: FamInstEnv
                           -> FamInst br            -- the putative new instance
                           -> [FamInst Branched]    -- Conflicting instances
lookupFamInstEnvConflicts' ie fi@(FamInst { fi_space = mb_space })
  | isFamilyTyCon fam
  , Just (FamIE insts) <- lookupUFM ie fam
  = case mb_space of
      Nothing -> insts
      Just (FamInstSpace { fis_tys = tys, fis_tcs = tcs }) ->
        filter (conflictsWith tys tcs mb_rhs) insts
  | otherwise = []
  where
    fam = famInstTyCon fi
    mb_rhs = if branched then Nothing
                         else Just famInstBranchRHS $ famInstSingleBranch fi

conflictsWith :: [Type]           -- type patterns of the new instance
              -> [Maybe Name]     -- rough match tycons of the new instance
              -> Maybe Type       -- if confluent overlap is possible, the rhs
              -> FamInst Branched -- do we conflict with this instance?
              -> Bool
conflictsWith _ _ _ (FamInst { fi_space = Nothing })
  = True -- if the space is Nothing, it conflicts with all other instances
conflictsWith tys rough_tcs mb_rhs
              fi@(FamInst { fi_branched = old_branched
                          , fi_space = Just (FamInstSpace { fis_tys = space_tys
                                                          , fis_tcs = space_tcs }) })
  | instanceCantMatch rough_tcs old_tcs
  = False -- no conflict here if the top-level structures don't match

  | otherwise 
  = ASSERT( tyVarsOfTypes tys `disjointVarSet` tyVarsOfTypes space_tys )
    case tcUnifyTys instanceBindFun tys space_tys of
                -- Unification will break badly if the variables overlap
                -- They shouldn't because we allocate separate uniques for them
      Just subst ->
        isDataFamilyTyCon tc ||
        isBranched old_branched ||
        rhs_conflict mb_rhs (famInstBranchRHS $ famInstSingleBranch fi) subst
          -- we don't need to check if the new instance is branched, because
          -- if it is, mb_rhs will be Nothing, and rhs_conflict will return True

      Nothing -> False -- no match

  where
    -- checks whether two RHSs are distinct, under a unifying substitution
    -- Note [Family instance overlap conflicts]
    rhs_conflict :: Maybe Type -> Type -> TvSubst -> Bool
    rhs_conflict Nothing _ _ = True -- the new instance does not participate in overlap
    rhs_conflict (Just rhs1) rhs2 subst 
      = not (rhs1' `eqType` rhs2')
        where
          rhs1' = substTy subst rhs1
          rhs2' = substTy subst rhs2

\end{code}

Note [Family instance overlap conflicts]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
- In the case of data family instances, any overlap is fundamentally a
  conflict (as these instances imply injective type mappings).

- In the case of type family instances, overlap is admitted as long as
  the neither instance declares an instance group and the right-hand
  sides of the overlapping rules coincide under the overlap substitution.
  For example:
       type instance F a Int = a
       type instance F Int b = b
  These two overlap on (F Int Int) but then both RHSs are Int,
  so all is well. We require that they are syntactically equal;
  anything else would be difficult to test for at this stage.

Note [Over-saturated matches]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
It's ok to look up an over-saturated type constructor.  E.g.
     type family F a :: * -> *
     type instance F (a,b) = Either (a->b)

The type instance gives rise to a newtype TyCon (at a higher kind
which you can't do in Haskell!):
     newtype FPair a b = FP (Either (a->b))

Then looking up (F (Int,Bool) Char) will return a FamInstMatch
     (FPair, [Int,Bool,Char])

The "extra" type argument [Char] just stays on the end.

\begin{code}

-- checks if one LHS is dominated by a list of other branches
-- in other words, if an application would match the first LHS, it is guaranteed
-- to match at least one of the others. The RHSs are ignored.
-- This algorithm is conservative:
--   True -> the LHS is definitely covered by the others
--   False -> no information
-- It is currently (Oct 2012) used only for generating errors for
-- inaccessible branches. If these errors go unreported, no harm done.
-- This is defined here to avoid a dependency from CoAxiom to Unify
isDominatedBy :: CoAxBranch -> [CoAxBranch] -> Bool
isDominatedBy branch branches
  = or $ map match branches
    where
      lhs = coAxBranchLHS branch
      match (CoAxBranch { cab_tvs = tvs, cab_lhs = tys })
        = isJust $ tcMatchTys (mkVarSet tvs) tys lhs
\end{code}


%************************************************************************
%*                                                                      *
                Looking up a family instance
%*                                                                      *
%************************************************************************

\begin{code}
topNormaliseType :: FamInstEnvs
                 -> Type
                 -> Maybe (Coercion, Type)

-- Get rid of *outermost* (or toplevel)
--      * type functions
--      * newtypes
-- using appropriate coercions.
-- By "outer" we mean that toplevelNormaliseType guarantees to return
-- a type that does not have a reducible redex (F ty1 .. tyn) as its
-- outermost form.  It *can* return something like (Maybe (F ty)), where
-- (F ty) is a redex.

-- Its a bit like Type.repType, but handles type families too

topNormaliseType env ty
  = go emptyNameSet ty
  where
    go :: NameSet -> Type -> Maybe (Coercion, Type)
    go rec_nts ty 
        | Just ty' <- coreView ty     -- Expand synonyms
        = go rec_nts ty'

        | Just (rec_nts', nt_co, nt_rhs) <- topNormaliseNewTypeX rec_nts ty
        = add_co nt_co rec_nts' nt_rhs

    go rec_nts (TyConApp tc tys) 
        | isFamilyTyCon tc              -- Expand open tycons
        , (co, ty) <- normaliseTcApp env tc tys
                -- Note that normaliseType fully normalises 'tys',
                -- wrt type functions but *not* newtypes
                -- It has do to so to be sure that nested calls like
                --    F (G Int)
                -- are correctly top-normalised
        , not (isReflCo co)
        = add_co co rec_nts ty

    go _ _ = Nothing

    add_co co rec_nts ty
        = case go rec_nts ty of
                Nothing         -> Just (co, ty)
                Just (co', ty') -> Just (mkTransCo co co', ty')


---------------
normaliseTcApp :: FamInstEnvs -> TyCon -> [Type] -> (Coercion, Type)
normaliseTcApp env tc tys
  | isFamilyTyCon tc
  , tyConArity tc <= length tys    -- Unsaturated data families are possible
  , [FamInstMatch { fim_instance = fam_inst
                  , fim_index    = fam_ind
                  , fim_tys      = inst_tys }] <- lookupFamInstEnv env tc ntys 
  = let    -- A matching family instance exists
        ax              = famInstAxiom fam_inst
        co              = mkAxInstCo  ax fam_ind inst_tys
        rhs             = mkAxInstRHS ax fam_ind inst_tys
        first_coi       = mkTransCo tycon_coi co
        (rest_coi,nty)  = normaliseType env rhs
        fix_coi         = mkTransCo first_coi rest_coi
    in 
    (fix_coi, nty)

  | otherwise   -- No unique matching family instance exists;
                -- we do not do anything (including for newtypes)
  = (tycon_coi, TyConApp tc ntys)

  where
        -- Normalise the arg types so that they'll match
        -- when we lookup in in the instance envt
    (cois, ntys) = mapAndUnzip (normaliseType env) tys
    tycon_coi    = mkTyConAppCo tc cois

---------------
normaliseType :: FamInstEnvs            -- environment with family instances
              -> Type                   -- old type
              -> (Coercion, Type)       -- (coercion,new type), where
                                        -- co :: old-type ~ new_type
-- Normalise the input type, by eliminating *all* type-function redexes
-- Returns with Refl if nothing happens
-- Does nothing to newtypes

normaliseType env ty
  | Just ty' <- coreView ty = normaliseType env ty'
normaliseType env (TyConApp tc tys)
  = normaliseTcApp env tc tys
normaliseType _env ty@(LitTy {}) = (Refl ty, ty)
normaliseType env (AppTy ty1 ty2)
  = let (coi1,nty1) = normaliseType env ty1
        (coi2,nty2) = normaliseType env ty2
    in  (mkAppCo coi1 coi2, mkAppTy nty1 nty2)
normaliseType env (FunTy ty1 ty2)
  = let (coi1,nty1) = normaliseType env ty1
        (coi2,nty2) = normaliseType env ty2
    in  (mkFunCo coi1 coi2, mkFunTy nty1 nty2)
normaliseType env (ForAllTy tyvar ty1)
  = let (coi,nty1) = normaliseType env ty1
    in  (mkForAllCo tyvar coi, ForAllTy tyvar nty1)
normaliseType _   ty@(TyVarTy _)
  = (Refl ty,ty)
\end{code}
