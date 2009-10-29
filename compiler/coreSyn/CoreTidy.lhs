%
% (c) The University of Glasgow 2006
% (c) The AQUA Project, Glasgow University, 1996-1998
%

This module contains "tidying" code for *nested* expressions, bindings, rules.
The code for *top-level* bindings is in TidyPgm.

\begin{code}
module CoreTidy (
	tidyExpr, tidyVarOcc, tidyRule, tidyRules 
    ) where

#include "HsVersions.h"

import CoreSyn
import CoreArity
import Id
import IdInfo
import Type
import Var
import VarEnv
import UniqFM
import Name hiding (tidyNameOcc)
import SrcLoc
import Maybes

import Data.List
\end{code}


%************************************************************************
%*									*
\subsection{Tidying expressions, rules}
%*									*
%************************************************************************

\begin{code}
tidyBind :: TidyEnv
	 -> CoreBind
	 ->  (TidyEnv, CoreBind)

tidyBind env (NonRec bndr rhs)
  = tidyLetBndr env (bndr,rhs) =: \ (env', bndr') ->
    (env', NonRec bndr' (tidyExpr env' rhs))

tidyBind env (Rec prs)
  = mapAccumL tidyLetBndr  env prs	=: \ (env', bndrs') ->
    map (tidyExpr env') (map snd prs)	=: \ rhss' ->
    (env', Rec (zip bndrs' rhss'))


------------  Expressions  --------------
tidyExpr :: TidyEnv -> CoreExpr -> CoreExpr
tidyExpr env (Var v)   	 =  Var (tidyVarOcc env v)
tidyExpr env (Type ty) 	 =  Type (tidyType env ty)
tidyExpr _   (Lit lit)   =  Lit lit
tidyExpr env (App f a) 	 =  App (tidyExpr env f) (tidyExpr env a)
tidyExpr env (Note n e)  =  Note (tidyNote env n) (tidyExpr env e)
tidyExpr env (Cast e co) =  Cast (tidyExpr env e) (tidyType env co)

tidyExpr env (Let b e) 
  = tidyBind env b 	=: \ (env', b') ->
    Let b' (tidyExpr env' e)

tidyExpr env (Case e b ty alts)
  = tidyBndr env b 	=: \ (env', b) ->
    Case (tidyExpr env e) b (tidyType env ty) 
	 (map (tidyAlt b env') alts)

tidyExpr env (Lam b e)
  = tidyBndr env b 	=: \ (env', b) ->
    Lam b (tidyExpr env' e)

------------  Case alternatives  --------------
tidyAlt :: CoreBndr -> TidyEnv -> CoreAlt -> CoreAlt
tidyAlt _case_bndr env (con, vs, rhs)
  = tidyBndrs env vs 	=: \ (env', vs) ->
    (con, vs, tidyExpr env' rhs)

------------  Notes  --------------
tidyNote :: TidyEnv -> Note -> Note
tidyNote _ note            = note

------------  Rules  --------------
tidyRules :: TidyEnv -> [CoreRule] -> [CoreRule]
tidyRules _   [] = []
tidyRules env (rule : rules)
  = tidyRule env rule  		=: \ rule ->
    tidyRules env rules 	=: \ rules ->
    (rule : rules)

tidyRule :: TidyEnv -> CoreRule -> CoreRule
tidyRule _   rule@(BuiltinRule {}) = rule
tidyRule env rule@(Rule { ru_bndrs = bndrs, ru_args = args, ru_rhs = rhs,
			  ru_fn = fn, ru_rough = mb_ns })
  = tidyBndrs env bndrs		=: \ (env', bndrs) ->
    map (tidyExpr env') args  	=: \ args ->
    rule { ru_bndrs = bndrs, ru_args = args, 
	   ru_rhs   = tidyExpr env' rhs,
	   ru_fn    = tidyNameOcc env fn, 
	   ru_rough = map (fmap (tidyNameOcc env')) mb_ns }
\end{code}


%************************************************************************
%*									*
\subsection{Tidying non-top-level binders}
%*									*
%************************************************************************

\begin{code}
tidyNameOcc :: TidyEnv -> Name -> Name
-- In rules and instances, we have Names, and we must tidy them too
-- Fortunately, we can lookup in the VarEnv with a name
tidyNameOcc (_, var_env) n = case lookupUFM var_env n of
				Nothing -> n
				Just v  -> idName v

tidyVarOcc :: TidyEnv -> Var -> Var
tidyVarOcc (_, var_env) v = lookupVarEnv var_env v `orElse` v

-- tidyBndr is used for lambda and case binders
tidyBndr :: TidyEnv -> Var -> (TidyEnv, Var)
tidyBndr env var
  | isTyVar var = tidyTyVarBndr env var
  | otherwise   = tidyIdBndr env var

tidyBndrs :: TidyEnv -> [Var] -> (TidyEnv, [Var])
tidyBndrs env vars = mapAccumL tidyBndr env vars

tidyLetBndr :: TidyEnv -> (Id, CoreExpr) -> (TidyEnv, Var)
-- Used for local (non-top-level) let(rec)s
tidyLetBndr env (id,rhs) 
  = ((tidy_env,new_var_env), final_id)
  where
    ((tidy_env,var_env), new_id) = tidyIdBndr env id

	-- We need to keep around any interesting strictness and
	-- demand info because later on we may need to use it when
	-- converting to A-normal form.
	-- eg.
	--	f (g x),  where f is strict in its argument, will be converted
	--	into  case (g x) of z -> f z  by CorePrep, but only if f still
	-- 	has its strictness info.
	--
	-- Similarly for the demand info - on a let binder, this tells 
	-- CorePrep to turn the let into a case.
	--
	-- Similarly arity info for eta expansion in CorePrep
	-- 
	-- Set inline-prag info so that we preseve it across 
	-- separate compilation boundaries
    final_id = new_id `setIdInfo` new_info
    idinfo   = idInfo id
    new_info = idInfo new_id
		`setArityInfo`		exprArity rhs
		`setAllStrictnessInfo`	newStrictnessInfo idinfo
		`setNewDemandInfo`	newDemandInfo idinfo
		`setInlinePragInfo`	inlinePragInfo idinfo

    -- Override the env we get back from tidyId with the new IdInfo
    -- so it gets propagated to the usage sites.
    new_var_env = extendVarEnv var_env id final_id

-- Non-top-level variables
tidyIdBndr :: TidyEnv -> Id -> (TidyEnv, Id)
tidyIdBndr env@(tidy_env, var_env) id
  = -- Do this pattern match strictly, otherwise we end up holding on to
    -- stuff in the OccName.
    case tidyOccName tidy_env (getOccName id) of { (tidy_env', occ') -> 
    let 
	-- Give the Id a fresh print-name, *and* rename its type
	-- The SrcLoc isn't important now, 
	-- though we could extract it from the Id
	-- 
        ty'      = tidyType env (idType id)
        name'    = mkInternalName (idUnique id) occ' noSrcSpan
	id'      = mkLocalIdWithInfo name' ty' new_info
	var_env' = extendVarEnv var_env id id'

	-- Note [Tidy IdInfo]
        new_info = vanillaIdInfo `setOccInfo` occInfo old_info
	old_info = idInfo id
    in
    ((tidy_env', var_env'), id')
   }
\end{code}

Note [Tidy IdInfo]
~~~~~~~~~~~~~~~~~~
All nested Ids now have the same IdInfo, namely vanillaIdInfo, which
should save some space; except that we preserve occurrence info for
two reasons:

  (a) To make printing tidy core nicer

  (b) Because we tidy RULES and InlineRules, which may then propagate
      via --make into the compilation of the next module, and we want
      the benefit of that occurrence analysis when we use the rule or
      or inline the function.  In particular, it's vital not to lose
      loop-breaker info, else we get an infinite inlining loop
      
Note that tidyLetBndr puts more IdInfo back.


\begin{code}
(=:) :: a -> (a -> b) -> b
m =: k = m `seq` k m
\end{code}
