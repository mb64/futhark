{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE DefaultSignatures #-}
-- | A generic transformation for adding memory allocations to a
-- Futhark program.  Specialised by specific representations in
-- submodules.
module Futhark.Pass.ExplicitAllocations
       ( explicitAllocationsGeneric
       , explicitAllocationsInStmsGeneric
       , ExpHint(..)
       , defaultExpHints

       , Allocable
       , Allocator(..)
       , AllocM
       , AllocEnv(..)
       , SizeSubst(..)
       , allocInStms
       , allocForArray

       , simplifiable
       , arraySizeInBytesExp

       , mkLetNamesB'
       , mkLetNamesB''

       -- * Module re-exports
       --
       -- These are highly likely to be needed by any downstream
       -- users.
       , module Control.Monad.Reader
       , module Futhark.MonadFreshNames
       , module Futhark.Pass
       , module Futhark.Tools
       )
where

import Futhark.Util.Pretty (pretty)
import Debug.Trace
import Control.Monad.State
import Control.Monad.Writer
import Control.Monad.Reader
import Control.Monad.RWS.Strict
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Maybe
import Data.List (zip4, partition, sort)

import Futhark.Optimise.Simplify.Lore
  (mkWiseBody, mkWiseLetStm, removeExpWisdom, removeScopeWisdom)
import Futhark.MonadFreshNames
import Futhark.Representation.Mem
import qualified Futhark.Representation.Mem.IxFun as IxFun
import Futhark.Tools
import qualified Futhark.Analysis.SymbolTable as ST
import Futhark.Optimise.Simplify.Engine (SimpleOps (..))
import qualified Futhark.Optimise.Simplify.Engine as Engine
import Futhark.Pass
import Futhark.Util (splitFromEnd, takeLast)

traceWith :: Show a => String -> a -> a
traceWith s a = trace (s ++ ": " ++ show a ++ "\n") a

data AllocStm = SizeComputation VName (PrimExp VName)
              | Allocation VName SubExp Space
              | ArrayCopy VName VName
                    deriving (Eq, Ord, Show)

bindAllocStm :: (MonadBinder m, Op (Lore m) ~ MemOp inner) =>
                AllocStm -> m ()
bindAllocStm (SizeComputation name pe) =
  letBindNames_ [name] =<< toExp (coerceIntPrimExp Int64 pe)
bindAllocStm (Allocation name size space) =
  letBindNames_ [name] $ Op $ Alloc size space
bindAllocStm (ArrayCopy name src) =
  letBindNames_ [name] $ BasicOp $ Copy src

class (MonadFreshNames m, HasScope lore m, Mem lore) =>
      Allocator lore m where
  addAllocStm :: AllocStm -> m ()
  askDefaultSpace :: m Space

  default addAllocStm :: (Allocable fromlore lore,
                          m ~ AllocM fromlore lore)
                      => AllocStm -> m ()
  addAllocStm (SizeComputation name se) =
    letBindNames_ [name] =<< toExp (coerceIntPrimExp Int64 se)
  addAllocStm (Allocation name size space) =
    letBindNames_ [name] $ Op $ allocOp size space
  addAllocStm (ArrayCopy name src) =
    letBindNames_ [name] $ BasicOp $ Copy src

  -- | The subexpression giving the number of elements we should
  -- allocate space for.  See 'ChunkMap' comment.
  dimAllocationSize :: SubExp -> m SubExp

  default dimAllocationSize :: m ~ AllocM fromlore lore
                               => SubExp -> m SubExp
  dimAllocationSize (Var v) =
    -- It is important to recurse here, as the substitution may itself
    -- be a chunk size.
    maybe (return $ Var v) dimAllocationSize =<< asks (M.lookup v . chunkMap)
  dimAllocationSize size =
    return size

  expHints :: Exp lore -> m [ExpHint]
  expHints = defaultExpHints

allocateMemory :: Allocator lore m =>
                  String -> SubExp -> Space -> m VName
allocateMemory desc size space = do
  v <- newVName desc
  addAllocStm $ Allocation v size space
  return v

computeSize :: Allocator lore m =>
               String -> PrimExp VName -> m SubExp
computeSize desc se = do
  v <- newVName desc
  addAllocStm $ SizeComputation v se
  return $ Var v

type Allocable fromlore tolore =
  (PrettyLore fromlore, PrettyLore tolore,
   Mem tolore,
   FParamAttr fromlore ~ DeclType,
   LParamAttr fromlore ~ Type,
   BranchType fromlore ~ ExtType,
   RetType fromlore ~ DeclExtType,
   BodyAttr fromlore ~ (),
   BodyAttr tolore ~ (),
   ExpAttr tolore ~ (),
   SizeSubst (Op tolore),
   BinderOps tolore)

-- | A mapping from chunk names to their maximum size.  XXX FIXME
-- HACK: This is part of a hack to add loop-invariant allocations to
-- reduce kernels, because memory expansion does not use range
-- analysis yet (it should).
type ChunkMap = M.Map VName SubExp

data AllocEnv fromlore tolore  =
  AllocEnv { chunkMap :: ChunkMap
           , aggressiveReuse :: Bool
             -- ^ Aggressively try to reuse memory in do-loops -
             -- should be True inside kernels, False outside.
           , allocSpace :: Space
             -- ^ When allocating memory, put it in this memory space.
             -- This is primarily used to ensure that group-wide
             -- statements store their results in local memory.
           , allocInOp :: Op fromlore -> AllocM fromlore tolore (Op tolore)
           , envExpHints :: Exp tolore -> AllocM fromlore tolore [ExpHint]
           }

boundDims :: ChunkMap -> AllocEnv fromlore tolore
          -> AllocEnv fromlore tolore
boundDims m env = env { chunkMap = m <> chunkMap env }

-- | Monad for adding allocations to an entire program.
newtype AllocM fromlore tolore a =
  AllocM (BinderT tolore (ReaderT (AllocEnv fromlore tolore) (State VNameSource)) a)
  deriving (Applicative, Functor, Monad,
             MonadFreshNames,
             HasScope tolore,
             LocalScope tolore,
             MonadReader (AllocEnv fromlore tolore))

instance (Allocable fromlore tolore, Allocator tolore (AllocM fromlore tolore)) =>
         MonadBinder (AllocM fromlore tolore) where
  type Lore (AllocM fromlore tolore) = tolore

  mkExpAttrM _ _ = return ()

  mkLetNamesM names e = do
    pat <- patternWithAllocations names e
    return $ Let pat (defAux ()) e

  mkBodyM bnds res = return $ Body () bnds res

  addStms binding = AllocM $ addBinderStms binding
  collectStms (AllocM m) = AllocM $ collectBinderStms m
  certifying cs (AllocM m) = AllocM $ certifyingBinder cs m

instance (Allocable fromlore tolore) =>
         Allocator tolore (AllocM fromlore tolore) where
  expHints e = do
    f <- asks envExpHints
    f e
  askDefaultSpace = asks allocSpace

runAllocM :: MonadFreshNames m =>
             (Op fromlore -> AllocM fromlore tolore (Op tolore))
          -> (Exp tolore -> AllocM fromlore tolore [ExpHint])
          -> AllocM fromlore tolore a -> m a
runAllocM handleOp hints (AllocM m) =
  fmap fst $ modifyNameSource $ runState $ runReaderT (runBinderT m mempty) env
  where env = AllocEnv mempty False DefaultSpace handleOp hints

-- | Monad for adding allocations to a single pattern.
newtype PatAllocM lore a = PatAllocM (RWS
                                      (Scope lore)
                                      [AllocStm]
                                      VNameSource
                                      a)
                    deriving (Applicative, Functor, Monad,
                              HasScope lore,
                              MonadWriter [AllocStm],
                              MonadFreshNames)

instance Mem lore => Allocator lore (PatAllocM lore) where
  addAllocStm = tell . pure
  dimAllocationSize = return
  askDefaultSpace = return DefaultSpace

runPatAllocM :: MonadFreshNames m =>
                PatAllocM lore a -> Scope lore
             -> m (a, [AllocStm])
runPatAllocM (PatAllocM m) mems =
  modifyNameSource $ frob . runRWS m mems
  where frob (a,s,w) = ((a,w),s)

arraySizeInBytesExp :: Type -> PrimExp VName
arraySizeInBytesExp t =
  product
    [ toInt64 $ product $ map (primExpFromSubExp int32) (arrayDims t)
    , ValueExp $ IntValue $ Int64Value $ primByteSize $ elemType t ]
  where toInt64 = ConvOpExp $ SExt Int32 Int64

arraySizeInBytesExpM :: Allocator lore m => Type -> m (PrimExp VName)
arraySizeInBytesExpM t = do
  dims <- mapM dimAllocationSize (arrayDims t)
  let dim_prod_i32 = product $ map (toInt64 . primExpFromSubExp int32) dims
  let elm_size_i64 = ValueExp $ IntValue $ Int64Value $ primByteSize $ elemType t
  return $ product [ dim_prod_i32, elm_size_i64 ]
  where toInt64 = ConvOpExp $ SExt Int32 Int64

arraySizeInBytes :: Allocator lore m => Type -> m SubExp
arraySizeInBytes = computeSize "bytes" <=< arraySizeInBytesExpM

-- | Allocate memory for a value of the given type.
allocForArray :: Allocator lore m =>
                 Type -> Space -> m VName
allocForArray t space = do
  size <- arraySizeInBytes t
  allocateMemory "mem" size space

allocsForStm :: (Allocator lore m, ExpAttr lore ~ ()) =>
                [Ident] -> [Ident] -> Exp lore
             -> m (Stm lore)
allocsForStm sizeidents validents e = do
  rts <- expReturns e
  hints <- expHints e
  (ctxElems, valElems) <- allocsForPattern sizeidents validents rts hints
  return $ Let (Pattern ctxElems valElems) (defAux ()) e

patternWithAllocations :: (Allocator lore m, ExpAttr lore ~ ()) =>
                          [VName]
                       -> Exp lore
                       -> m (Pattern lore)
patternWithAllocations names e = do
  (ts',sizes) <- instantiateShapes' =<< expExtType e
  let identForBindage name t =
        pure $ Ident name t
  vals <- sequence [ identForBindage name t | (name, t) <- zip names ts' ]
  stmPattern <$> allocsForStm sizes vals e

allocsForPattern :: Allocator lore m =>
                    [Ident] -> [Ident] -> [ExpReturns] -> [ExpHint]
                 -> m ([PatElem lore],
                       [PatElem lore])
allocsForPattern sizeidents validents rts hints = do
  let sizes' = [ PatElem size $ MemPrim int32 | size <- map identName sizeidents ]
  (vals, (exts, mems)) <-
    runWriterT $ forM (zip3 validents rts hints) $ \(ident, rt, hint) -> do
      let shape = arrayShape $ identType ident
      case rt of
        MemPrim _ -> do
          summary <- lift $ summaryForBindage (identType ident) hint
          return $ PatElem (identName ident) summary

        MemMem space ->
          return $ PatElem (identName ident) $
          MemMem space

        MemArray bt _ u (Just (ReturnsInBlock mem extixfun)) -> do
          (patels, ixfn) <- instantiateExtIxFun ident extixfun
          tell (patels, [])

          return $ PatElem (identName ident) $
            MemArray bt shape u $
            ArrayIn mem ixfn

        MemArray _ extshape _ Nothing
          | Just _ <- knownShape extshape -> do
            summary <- lift $ summaryForBindage (identType ident) hint
            return $ PatElem (identName ident) summary

        MemArray bt _ u (Just (ReturnsNewBlock space _ extixfn)) -> do
          -- treat existential index function first
          (patels, ixfn) <- instantiateExtIxFun ident extixfn
          tell (patels, [])

          memid <- lift $ mkMemIdent ident space
          tell ([], [PatElem (identName memid) $ MemMem space])
          return $ PatElem (identName ident) $ MemArray bt shape u $
            ArrayIn (identName memid) ixfn

        _ -> error "Impossible case reached in allocsForPattern!"

  return (sizes' <> exts <> mems,
          vals)
  where knownShape = mapM known . shapeDims
        known (Free v) = Just v
        known Ext{} = Nothing

        mkMemIdent :: (MonadFreshNames m) => Ident -> Space -> m Ident
        mkMemIdent ident space = do
          let memname = baseString (identName ident) <> "_mem"
          newIdent memname $ Mem space

        instantiateExtIxFun :: MonadFreshNames m =>
                               Ident -> ExtIxFun ->
                               m ([PatElemT (MemInfo d u ret)], IxFun)
        instantiateExtIxFun idd ext_ixfn = do
          let isAndPtps = S.toList $
                          foldMap onlyExts $
                          foldMap leafExpTypes ext_ixfn

          -- Find the existentials that reuse the sizeidents, and
          -- those that need new pattern elements.  Assumes that the
          -- Exts form a contiguous interval of integers.
          let (size_exts, new_exts) =
                span ((<length sizeidents) . fst) $ sort isAndPtps
          (new_substs, patels) <-
            fmap unzip $ forM new_exts $ \(i, t) -> do
            v <- newVName $ baseString (identName idd) <> "_ixfn"
            return ((Ext i, LeafExp (Free v) t),
                    PatElem v $ MemPrim t)
          let size_substs = zipWith (\(i, t) ident ->
                                    (Ext i, LeafExp (Free (identName ident)) t))
                            size_exts sizeidents
              substs = M.fromList $ new_substs <> size_substs
          ixfn <- instantiateIxFun $ IxFun.substituteInIxFun substs ext_ixfn

          return (patels, ixfn)

onlyExts :: (Ext a, PrimType) -> S.Set (Int, PrimType)
onlyExts (Free _, _) = S.empty
onlyExts (Ext i, t) = S.singleton (i, t)


instantiateIxFun :: Monad m => ExtIxFun -> m IxFun
instantiateIxFun = traverse $ traverse inst
  where inst Ext{} = error "instantiateIxFun: not yet"
        inst (Free x) = return x

summaryForBindage :: Allocator lore m =>
                     Type -> ExpHint
                  -> m (MemBound NoUniqueness)
summaryForBindage (Prim bt) _ =
  return $ MemPrim bt
summaryForBindage (Mem space) _ =
  return $ MemMem space
summaryForBindage t@(Array bt shape u) NoHint = do
  m <- allocForArray t =<< askDefaultSpace
  return $ directIxFun bt shape u m t
summaryForBindage t (Hint ixfun space) = do
  let bt = elemType t
  bytes <- computeSize "bytes" $
           product [ConvOpExp (SExt Int32 Int64) (product (IxFun.base ixfun)),
                    fromIntegral (primByteSize (elemType t)::Int64)]
  m <- allocateMemory "mem" bytes space
  return $ MemArray bt (arrayShape t) NoUniqueness $ ArrayIn m ixfun

lookupMemSpace :: (HasScope lore m, Monad m) => VName -> m Space
lookupMemSpace v = do
  t <- lookupType v
  case t of
    Mem space -> return space
    _ -> error $ "lookupMemSpace: " ++ pretty v ++ " is not a memory block."

directIxFun :: PrimType -> Shape -> u -> VName -> Type -> MemBound u
directIxFun bt shape u mem t =
  MemArray bt shape u $ ArrayIn mem $
  IxFun.iota $ map (primExpFromSubExp int32) $ arrayDims t

allocInFParams :: (Allocable fromlore tolore) =>
                  [(FParam fromlore, Space)] ->
                  ([FParam tolore] -> AllocM fromlore tolore a)
               -> AllocM fromlore tolore a
allocInFParams params m = do
  (valparams, memparams) <-
    runWriterT $ mapM (uncurry allocInFParam) params
  let params' = memparams <> valparams
      summary = scopeOfFParams params'
  localScope summary $ m params'

allocInFParam :: (Allocable fromlore tolore) =>
                 FParam fromlore
              -> Space
              -> WriterT [FParam tolore]
                 (AllocM fromlore tolore) (FParam tolore)
allocInFParam param pspace =
  case paramDeclType param of
    Array bt shape u -> do
      let memname = baseString (paramName param) <> "_mem"
          ixfun = IxFun.iota $ map (primExpFromSubExp int32) $ shapeDims shape
      mem <- lift $ newVName memname
      tell [Param mem $ MemMem pspace]
      return param { paramAttr =  MemArray bt shape u $ ArrayIn mem ixfun }
    Prim bt ->
      return param { paramAttr  = MemPrim bt }
    Mem space ->
      return param { paramAttr = MemMem space }

allocInMergeParams :: (Allocable fromlore tolore,
                       Allocator tolore (AllocM fromlore tolore)) =>
                      [VName]
                   -> [(FParam fromlore,SubExp)]
                   -> ([FParam tolore]
                       -> [FParam tolore]
                       -> ([SubExp] -> AllocM fromlore tolore ([SubExp], [SubExp]))
                       -> AllocM fromlore tolore a)
                   -> AllocM fromlore tolore a
allocInMergeParams variant merge m = do
  ((valparams, handle_loop_subexps), mem_params) <-
    runWriterT $ unzip <$> mapM allocInMergeParam merge
  let mergeparams' = mem_params <> valparams
      summary = scopeOfFParams mergeparams'

      mk_loop_res ses = do
        (valargs, memargs) <-
          runWriterT $ zipWithM ($) handle_loop_subexps ses
        return (memargs, valargs)

  localScope summary $ m mem_params valparams mk_loop_res
  where allocInMergeParam (mergeparam, Var v)
          | Array bt shape u <- paramDeclType mergeparam = do
              (mem, ixfun) <- lift $ lookupArraySummary v
              space <- lift $ lookupMemSpace mem
              reuse <- asks aggressiveReuse
              if space /= Space "local" &&
                 reuse &&
                 u == Unique &&
                 loopInvariantShape mergeparam
                then return (mergeparam { paramAttr = MemArray bt shape Unique $ ArrayIn mem ixfun },
                             lift . ensureArrayIn (paramType mergeparam) mem ixfun)
                else do def_space <- asks allocSpace
                        doDefault mergeparam def_space

        allocInMergeParam (mergeparam, _) = doDefault mergeparam =<< lift askDefaultSpace

        doDefault mergeparam space = do
          mergeparam' <- allocInFParam mergeparam space
          return (mergeparam', linearFuncallArg (paramType mergeparam) space)

        variant_names = variant ++ map (paramName . fst) merge
        loopInvariantShape =
          not . any (`elem` variant_names) . subExpVars . arrayDims . paramType

ensureArrayIn :: (Allocable fromlore tolore,
                  Allocator tolore (AllocM fromlore tolore)) =>
                 Type -> VName -> IxFun -> SubExp
              -> AllocM fromlore tolore SubExp
ensureArrayIn _ _ _ (Constant v) =
  error $ "ensureArrayIn: " ++ pretty v ++ " cannot be an array."
ensureArrayIn t mem ixfun (Var v) = do
  (src_mem, src_ixfun) <- lookupArraySummary v
  if src_mem == mem && src_ixfun == ixfun
    then return $ Var v
    else do copy <- newIdent (baseString v ++ "_ensure_copy") t
            let summary = MemArray (elemType t) (arrayShape t) NoUniqueness $
                          ArrayIn mem ixfun
                pat = Pattern [] [PatElem (identName copy) summary]
            letBind_ pat $ BasicOp $ Copy v
            return $ Var $ identName copy

ensureDirectArray :: (Allocable fromlore tolore,
                      Allocator tolore (AllocM fromlore tolore)) =>
                     Maybe Space -> VName -> AllocM fromlore tolore (VName, SubExp)
ensureDirectArray space_ok v = do
  (mem, ixfun) <- lookupArraySummary v
  mem_space <- lookupMemSpace mem
  default_space <- askDefaultSpace
  if IxFun.isDirect ixfun && maybe True (==mem_space) space_ok
    then return (mem, Var v)
    else needCopy (fromMaybe default_space space_ok)
  where needCopy space =
          -- We need to do a new allocation, copy 'v', and make a new
          -- binding for the size of the memory block.
          allocLinearArray space (baseString v) v

allocLinearArray :: (Allocable fromlore tolore, Allocator tolore (AllocM fromlore tolore)) =>
                    Space -> String -> VName
                 -> AllocM fromlore tolore (VName, SubExp)
allocLinearArray space s v = do
  t <- lookupType v
  mem <- allocForArray t space
  v' <- newIdent (s ++ "_linear") t
  let pat = Pattern [] [PatElem (identName v') $
                        directIxFun (elemType t) (arrayShape t)
                        NoUniqueness mem t]
  addStm $ Let pat (defAux ()) $ BasicOp $ Copy v
  return (mem, Var $ identName v')

funcallArgs :: (Allocable fromlore tolore,
                Allocator tolore (AllocM fromlore tolore)) =>
               [(SubExp,Diet)] -> AllocM fromlore tolore [(SubExp,Diet)]
funcallArgs args = do
  (valargs, mem_and_size_args) <- runWriterT $ forM args $ \(arg,d) -> do
    t <- lift $ subExpType arg
    space <- lift askDefaultSpace
    arg' <- linearFuncallArg t space arg
    return (arg', d)
  return $ map (,Observe) mem_and_size_args <> valargs

linearFuncallArg :: (Allocable fromlore tolore,
                     Allocator tolore (AllocM fromlore tolore)) =>
                    Type -> Space -> SubExp
                 -> WriterT [SubExp] (AllocM fromlore tolore) SubExp
linearFuncallArg Array{} space (Var v) = do
  (mem, arg') <- lift $ ensureDirectArray (Just space) v
  tell [Var mem]
  return arg'
linearFuncallArg _ _ arg =
  return arg

explicitAllocationsGeneric :: (Allocable fromlore tolore,
                               Allocator tolore (AllocM fromlore tolore)) =>
                              (Op fromlore -> AllocM fromlore tolore (Op tolore))
                           -> (Exp tolore -> AllocM fromlore tolore [ExpHint])
                           -> Pass fromlore tolore
explicitAllocationsGeneric handleOp hints =
  Pass "explicit allocations" "Transform program to explicit memory representation" $
  intraproceduralTransformationWithConsts onStms allocInFun
  where onStms stms = runAllocM handleOp hints $ allocInStms stms pure

        allocInFun consts (FunDef entry fname rettype params fbody) =
          runAllocM handleOp hints $ inScopeOf consts $
          allocInFParams (zip params $ repeat DefaultSpace) $ \params' -> do
          fbody' <- insertStmsM $ allocInFunBody
                    (map (const $ Just DefaultSpace) rettype) fbody
          return $ FunDef entry fname (memoryInDeclExtType rettype) params' fbody'

explicitAllocationsInStmsGeneric :: (MonadFreshNames m, HasScope tolore m,
                                     Allocable fromlore tolore) =>
                                    (Op fromlore -> AllocM fromlore tolore (Op tolore))
                                 -> (Exp tolore -> AllocM fromlore tolore [ExpHint])
                                 -> Stms fromlore -> m (Stms tolore)
explicitAllocationsInStmsGeneric handleOp hints stms = do
  scope <- askScope
  runAllocM handleOp hints $ localScope scope $ allocInStms stms return

memoryInDeclExtType :: [DeclExtType] -> [FunReturns]
memoryInDeclExtType ts = evalState (mapM addAttr ts) $ startOfFreeIDRange ts
  where addAttr (Prim t) = return $ MemPrim t
        addAttr Mem{} = error "memoryInDeclExtType: too much memory"
        addAttr (Array bt shape u) = do
          i <- get <* modify (+1)
          return $ MemArray bt shape u $ ReturnsNewBlock DefaultSpace i $
            IxFun.iota $ map convert $ shapeDims shape

startOfFreeIDRange :: [TypeBase ExtShape u] -> Int
startOfFreeIDRange = S.size . shapeContext

bodyReturnMemCtx :: (Allocable fromlore tolore, Allocator tolore (AllocM fromlore tolore)) =>
                    SubExp -> AllocM fromlore tolore [SubExp]
bodyReturnMemCtx Constant{} =
  return []
bodyReturnMemCtx (Var v) = do
  info <- lookupMemInfo v
  case info of
    MemPrim{} -> return []
    MemMem{} -> return [] -- should not happen
    MemArray _ _ _ (ArrayIn mem _) -> return [Var mem]

allocInFunBody :: (Allocable fromlore tolore, Allocator tolore (AllocM fromlore tolore)) =>
                  [Maybe Space] -> Body fromlore -> AllocM fromlore tolore (Body tolore)
allocInFunBody space_oks (Body _ bnds res) =
  allocInStms bnds $ \bnds' -> do
    (res'', allocs) <- collectStms $ do
      res' <- zipWithM ensureDirect space_oks' res
      let (ctx_res, val_res) = splitFromEnd num_vals res'
      mem_ctx_res <- concat <$> mapM bodyReturnMemCtx val_res
      return $ ctx_res <> mem_ctx_res <> val_res
    return $ Body () (bnds'<>allocs) res''
  where num_vals = length space_oks
        space_oks' = replicate (length res - num_vals) Nothing ++ space_oks

ensureDirect :: (Allocable fromlore tolore, Allocator tolore (AllocM fromlore tolore)) =>
                Maybe Space -> SubExp -> AllocM fromlore tolore SubExp
ensureDirect _ se@Constant{} = return se
ensureDirect space_ok (Var v) = do
  bt <- primType <$> lookupType v
  if bt
    then return $ Var v
    else do (_, v') <- ensureDirectArray space_ok v
            return v'

allocInStms :: (Allocable fromlore tolore) =>
               Stms fromlore -> (Stms tolore -> AllocM fromlore tolore a)
            -> AllocM fromlore tolore a
allocInStms origbnds m = allocInStms' (stmsToList origbnds) mempty
  where allocInStms' [] bnds' =
          m bnds'
        allocInStms' (x:xs) bnds' = do
          allocbnds <- allocInStm' x
          localScope (scopeOf allocbnds) $
            local (boundDims $ mconcat $ map sizeSubst $ stmsToList allocbnds) $
            allocInStms' xs (bnds'<>allocbnds)
        allocInStm' bnd = do
          ((),bnds') <- collectStms $ certifying (stmCerts bnd) $ allocInStm bnd
          return bnds'

allocInStm :: (Allocable fromlore tolore, Allocator tolore (AllocM fromlore tolore)) =>
              Stm fromlore -> AllocM fromlore tolore ()
allocInStm (Let (Pattern sizeElems valElems) _ e) = do
  e' <- allocInExp e
  let sizeidents = map patElemIdent sizeElems
      validents = map patElemIdent valElems
  bnd <- allocsForStm sizeidents validents e'
  addStm bnd

allocInExp :: (Allocable fromlore tolore, Allocator tolore (AllocM fromlore tolore)) =>
              Exp fromlore -> AllocM fromlore tolore (Exp tolore)
allocInExp (DoLoop ctx vals form body@(Body bodyattrs bodybnds bodyres)) = do
  let ctx' = traceWith "ctx'" $ map allocInCtx ctx
  init_ixfuns <- mapM bodyReturnMIxf $ map snd  $ traceWith "vals" vals
  init_spaces <- mapM ixfunSpace $ traceWith "init_ixfuns" init_ixfuns
  form' <- allocInLoopForm $
           trace (unwords ["form: ", show form,
                           "\n\ninit_ixfuns: ", show init_ixfuns,
                           "\n\ninit_spaces: ", show init_spaces]) form
  localScope (scopeOf $ traceWith "localScope.form'" form') $ do
    -- The variables from vals are not in scope when trying to compute allocInStms, and so this crashes.
    let (body', init_spaces_and_subs) = pairM $
                                        trace "or here?"
                                        allocInStms (traceWith "bodybnds:" bodybnds) $
                                        trace "Did we get to here?"
                                        allocInLoopBodyBinds $
                                        trace (unwords ["form blab: ", show form,
                                                        "\n\ninit_ixfuns: ", show init_ixfuns,
                                                        "\n\ninit_spaces: ", show init_spaces,
                                                        "\n\nform': ", show form']) $
                                        zip init_spaces init_ixfuns
    body'' <- insertStmsM body'
    (init_spaces', init_subs) <- init_spaces_and_subs
    (newctx, vals')  <- foldM substituteInVal ([], []) $ zip3 vals init_spaces' init_subs
    return $
      DoLoop
      (ctx' <> newctx)
      vals'
      (traceWith "form'" form')
      body''
  where
    pairM :: Monad m => m (a, b) -> (m a, m b)
    pairM m =
      (fst <$> m, snd <$> m)

    -- allocInCtx :: (Param DeclType, subexp) -> (Param (MemBound uniqueness), subexp)
    allocInCtx (param, subexp) =
      case paramDeclType param of
        Prim bt -> (param { paramAttr = MemPrim bt }, subexp)
        Mem space -> (param { paramAttr = MemMem space }, subexp)
        Array _ _ _ -> error "Impossible, context cannot contain array"

    allocInParam' :: (Allocable fromlore tolore, Allocator tolore (AllocM fromlore tolore)) =>
                   Space -> FParam fromlore -> AllocM fromlore tolore (FParam tolore)
    allocInParam' space param =
      case paramDeclType param of
        Prim bt -> return $ param { paramAttr = MemPrim bt }
        Mem space' -> return $ param { paramAttr = MemMem space' }
        Array pt shape u -> error "Impossible in allocInParam'"

    ixfunSpace x =
      case x of
        Just (ArrayIn mem _) -> do
          meminfo <- lookupMemInfo $ traceWith "looking it up" mem
          case meminfo of
            MemMem space -> return $ Just $ traceWith "returning it" space
            _ -> return $ traceWith "returning it 2" Nothing
        _ -> return $ traceWith "returning it 3" Nothing

    allocInLoopBodyBinds init_res_and_ixfuns bodybnds = do
      bodyres_ixfuns <- mapM bodyReturnMIxf $ drop (length ctx) $ traceWith "allocInLoopBodyBinds.bodyres" bodyres
      bodyres_spaces <- mapM ixfunSpace $ traceWith "allocInLoopBodyBinds.bodyres_ixfuns" bodyres_ixfuns
      let (spaces, subs) = unzip $
                           zipWith generalize
                           init_res_and_ixfuns
                           (zip bodyres_spaces bodyres_ixfuns)
          init_subs = map (selectSub fst) subs
          res_subs = map (selectSub snd) subs
          body' = Body () bodybnds bodyres
      res_body <- addResCtxInLoopBody body' spaces $ traceWith "going to add res on res_subs" res_subs
      return (res_body, (spaces, init_subs))

    -- generalize :: (Maybe Space, Maybe MemBind) -> (Maybe Space, Maybe MemBind)
    --            -> (Maybe Space, Maybe (IxFun, [(PrimExp VName, PrimExp VName)]))
    -- generalize (Just sp1, Just (ArrayIn _ ixf1)) (Just sp2, Just (ArrayIn _ ixf2)) =
    --   if sp1 /= sp2 then (Just sp1, Nothing)
    --   else case IxFun.leastGeneralGeneralization ixf1 ixf2 of
    --     Just (ixf, m) -> (Just sp1, Just (ixf, m))
    --     Nothing -> (Just sp1, Nothing)
    -- generalize (mbsp1, _) _ = (mbsp1, Nothing)

    generalize :: (Maybe Space, Maybe MemBind) -> (Maybe Space, Maybe MemBind)
               -> (Maybe Space, Maybe (ExtIxFun, [(PrimExp VName, PrimExp VName)]))
    generalize (Just sp1, Just (ArrayIn _ ixf1)) (Just sp2, Just (ArrayIn _ ixf2)) =
      if sp1 /= sp2 then (Just sp1, Nothing)
      else case IxFun.leastGeneralGeneralization ixf1 ixf2 of
             Just (ixf, m) -> (Just sp1, Just (ixf, m))
             Nothing -> (Just sp1, Nothing)
    generalize (mbsp1, _) _ = (mbsp1, Nothing)


    substituteInVal :: (Allocable fromlore tolore,
                         Allocator tolore (AllocM fromlore tolore)) =>
                       ([(FParam tolore, SubExp)], [(FParam tolore, SubExp)])
                    -> ((FParam fromlore, SubExp), Maybe Space, Maybe (ExtIxFun, [PrimExp VName]))
                    -> AllocM
                       fromlore
                       tolore
                       ([(FParam tolore, SubExp)], [(FParam tolore, SubExp)])
    substituteInVal (ctx_acc, val_acc) ((param, val), space, subst) =
      case subst of
        Nothing -> do -- Does not generalize
          val' <- ensureDirect space val
          let space' = fromMaybe DefaultSpace space
          param' <- allocInParam' space' param
          return $ (ctx_acc,
                    val_acc ++ [(param', val')])
        Just (ixfun, m) -> do -- Generalizes
          let i = length m
              ixfun' = IxFun.substituteInIxFun (M.fromList $ zip (fmap Ext [0..]) (fmap (fmap Free) m)) ixfun
          ixfun'' <- trace ("ixfun: " ++ show ixfun ++ "\n\nm: " ++ show m++"\n\n") instantiateIxFun ixfun'
          param' <- case paramDeclType param of
                Array pt shape u -> do
                  vname <- newVName "existential_param"
                  return $ param { paramAttr = MemArray pt shape u $ ArrayIn vname ixfun'' }
                _ -> error "impossible in substituteInVal"
          existentials <- mapM (primExpToSubExp "ixfn_exist"
                                (return . BasicOp . SubExp . Var))
                          m
          existential_params <- mapM (\existential -> do
                                         meminfo <- subExpMemInfo existential
                                         let meminfo' =
                                               case meminfo of
                                                 MemPrim pt -> MemPrim pt
                                                 MemMem sp -> MemMem sp
                                                 MemArray _ _ _ _ -> error "impossible existential_params"
                                         newParam "existential_param" $ meminfo')
                                existentials
          return $
            (ctx_acc ++ zip existential_params
              existentials,
             val_acc ++ [(param', val)])

allocInExp (Apply fname args rettype loc) = do
  args' <- funcallArgs args
  return $ Apply fname args' (memoryInDeclExtType rettype) loc
allocInExp (If cond tbranch0 fbranch0 (IfAttr rets ifsort)) = do
  let num_rets = length rets
  -- switch to the explicit-mem rep, but do nothing about results
  (tbranch, tm_ixfs) <- allocInIfBody num_rets tbranch0
  (fbranch, fm_ixfs) <- allocInIfBody num_rets fbranch0
  tspaces <- mkSpaceOks num_rets tbranch
  fspaces <- mkSpaceOks num_rets fbranch
  -- try to generalize (antiunify) the index functions of the then and else bodies
  let sp_substs = zipWith generalize (zip tspaces tm_ixfs) (zip fspaces fm_ixfs)
      (spaces, subs) = unzip sp_substs
      tsubs = map (selectSub fst) subs
      fsubs = map (selectSub snd) subs
  (tbranch', trets) <- addResCtxInIfBody rets tbranch spaces tsubs
  (fbranch', frets) <- addResCtxInIfBody rets fbranch spaces fsubs
  if frets /= trets then error "In allocInExp, IF case: antiunification of then/else produce different ExtInFn!"
    else do -- above is a sanity check; implementation continues on else branch
    let res_then = bodyResult tbranch'
        res_else = bodyResult fbranch'
        size_ext = length res_then - length trets
        (ind_ses0, r_then_else) =
            partition (\(r_then, r_else, _) -> r_then == r_else) $
            zip3 res_then res_else [0 .. size_ext - 1]
        (r_then_ext, r_else_ext, _) = unzip3 r_then_else
        ind_ses = zipWith (\(se, _, i) k -> (i-k, se)) ind_ses0
                  [0 .. length ind_ses0 - 1]
        rets'' = foldl (\acc (i, se) -> fixExt i se acc) trets ind_ses
        tbranch'' = tbranch' { bodyResult = r_then_ext ++ drop size_ext res_then }
        fbranch'' = fbranch' { bodyResult = r_else_ext ++ drop size_ext res_else }
        res_if_expr = If cond tbranch'' fbranch'' $ IfAttr rets'' ifsort
    return res_if_expr
      where
        generalize :: (Maybe Space, Maybe MemBind) -> (Maybe Space, Maybe MemBind)
                   -> (Maybe Space, Maybe (ExtIxFun, [(PrimExp VName, PrimExp VName)]))
        generalize (Just sp1, Just (ArrayIn _ ixf1)) (Just sp2, Just (ArrayIn _ ixf2)) =
          if sp1 /= sp2 then (Just sp1, Nothing)
          else case IxFun.leastGeneralGeneralization ixf1 ixf2 of
            Just (ixf, m) -> (Just sp1, Just (ixf, m))
            Nothing -> (Just sp1, Nothing)
        generalize (mbsp1, _) _ = (mbsp1, Nothing)


allocInExp e = mapExpM alloc e
  where alloc =
          identityMapper { mapOnBody = error "Unhandled Body in ExplicitAllocations"
                         , mapOnRetType = error "Unhandled RetType in ExplicitAllocations"
                         , mapOnBranchType = error "Unhandled BranchType in ExplicitAllocations"
                         , mapOnFParam = error "Unhandled FParam in ExplicitAllocations"
                         , mapOnLParam = error "Unhandled LParam in ExplicitAllocations"
                         , mapOnOp = \op -> do handle <- asks allocInOp
                                               handle op
                         }

selectSub :: ((a, a) -> a) -> Maybe (ExtIxFun, [(a, a)]) ->
             Maybe (ExtIxFun, [a])
selectSub f (Just (ixfn, m)) = Just (ixfn, map f m)
selectSub _ Nothing = Nothing

-- | Just introduces the new representation (index functions); but
-- does not unify (e.g., does not ensures direct); implementation
-- extends `allocInBodyNoDirect`, but also return `MemBind`
allocInIfBody :: (Allocable fromlore tolore, Allocator tolore (AllocM fromlore tolore)) =>
                 Int -> Body fromlore -> AllocM fromlore tolore (Body tolore, [Maybe MemBind])
allocInIfBody num_vals (Body _ bnds res) =
  allocInStms bnds $ \bnds' -> do
    let (_, val_res) = splitFromEnd num_vals res
    mem_ixfs <- mapM bodyReturnMIxf val_res
    return (Body () bnds' res, mem_ixfs)

bodyReturnMIxf :: (Allocable fromlore tolore, Allocator tolore (AllocM fromlore tolore)) =>
                  SubExp -> AllocM fromlore tolore (Maybe MemBind)
bodyReturnMIxf Constant{} = return Nothing
bodyReturnMIxf (Var v) = do
  info <- lookupMemInfo v
  case info of
    MemArray _ptp _shp _u mem_ixf -> return $ Just mem_ixf
    _ -> return Nothing

-- addResCtxInLoopBody :: (Allocable fromlore tolore, Allocator tolore (AllocM fromlore tolore)) =>
--                        Body tolore ->
--                        [Maybe Space] ->
--                        [Maybe (ExtIxFun, [PrimExp VName])] ->
--                        AllocM fromlore tolore (Body tolore)
addResCtxInLoopBody (Body () bnds res) spaces substs = do
  let num_vals = length substs
      (ctx_res, val_res) = splitFromEnd num_vals res
  (res', all_body_stms) <- collectStms $ do
      mapM_ addStm bnds
      (val_res', ext_ses_res, mem_ctx_res) <-
        foldM helper ([], [], []) (zip3 val_res substs spaces)
      return $ ctx_res <> ext_ses_res <> mem_ctx_res <> val_res'
  body' <- mkBodyM all_body_stms res'
  return body'
    where
      helper (res_acc, ext_acc, ctx_acc) (r, mbixfsub, sp) =
        case mbixfsub of
          Nothing -> do
            r' <- ensureDirect sp r
            mem_ctx_r <- bodyReturnMemCtx r'
            r_mem <- subExpMemInfo r'
            let r_mem' = inspect2 r_mem sp
            return (res_acc ++ [r'],
                    ext_acc,
                    ctx_acc ++ mem_ctx_r)
          Just (ixfn, m) -> do -- generalizes
            -- Not needed since we only return a subexp from here, the index function is derived from the merge parameters
            -- ixfun' <- instantiateIxFun $ IxFun.substituteInIxFun m ixfun
            -- param' <- case paramDeclType param of
            --             Array pt shape u -> do
            --               vname <- newVName "existential_param"
            --               param { paramAttr = MemArray pt shape u $ ArrayIn vname ixfun' }
            --             _ -> error "impossible in substituteInVal"
            let i = length m
            ext_ses <- mapM (primExpToSubExp "ixfn_exist"
                            (return . BasicOp . SubExp .Var))
                       m
            mem_ctx_r <- bodyReturnMemCtx r
            return (res_acc ++ [r],
                    ext_acc ++ ext_ses,
                    ctx_acc ++ mem_ctx_r)

inspect2 :: MemInfo SubExp u MemBind -> Maybe Space ->  MemInfo (Ext SubExp) u MemReturn
inspect2 (MemArray pt shape u ret) space =
  let space' = fromMaybe DefaultSpace space
      bodyret = MemArray pt (fmap Free shape) u $ ReturnsNewBlock space' 0 $
        IxFun.iota $ map convert $ fmap Free $ shapeDims shape
  in bodyret
inspect2 (MemPrim pt) _ = MemPrim pt
inspect2 (MemMem space) _ = MemMem space


addResCtxInIfBody :: (Allocable fromlore tolore, Allocator tolore (AllocM fromlore tolore)) =>
                     [ExtType] -> Body tolore -> [Maybe Space] ->
                     [Maybe (ExtIxFun, [PrimExp VName])] ->
                     AllocM fromlore tolore (Body tolore, [BodyReturns])
addResCtxInIfBody ifrets (Body _ bnds res) spaces substs = do
  let num_vals = length ifrets
      (ctx_res, val_res) = splitFromEnd num_vals res
  ((res', bodyrets'), all_body_stms) <- collectStms $ do
    mapM_ addStm bnds
    (val_res', ext_ses_res, mem_ctx_res, bodyrets, total_existentials) <-
      foldM helper ([], [], [], [], length ctx_res) (zip4 ifrets val_res substs spaces)
    return (ctx_res <> ext_ses_res <> mem_ctx_res <> val_res',
             -- We need to adjust the ReturnsNewBlock existentials, because they
             -- should always be numbered _after_ all other existentials in the
             -- return values.
            reverse $ fst $ foldl adjustNewBlockExistential ([], total_existentials) bodyrets)
  body' <- mkBodyM all_body_stms res'
  return (body', bodyrets')
    where
      helper (res_acc, ext_acc, ctx_acc, br_acc, k) (ifr, r, mbixfsub, sp) =
        case mbixfsub of
          Nothing -> do
            -- does NOT generalize/antiunify; ensure direct
            r' <- ensureDirect sp r
            mem_ctx_r <- bodyReturnMemCtx r'
            let body_ret = inspect ifr sp
            return (res_acc ++ [r'],
                    ext_acc,
                    ctx_acc ++ mem_ctx_r,
                    br_acc ++ [body_ret],
                    k)
          Just (ixfn, m) -> do -- generalizes
            let i = length m
            ext_ses <- mapM (primExpToSubExp "ixfn_exist"
                             (return . BasicOp . SubExp . Var))
                       m
            mem_ctx_r <- bodyReturnMemCtx r
            let sp' = fromMaybe DefaultSpace sp
                ixfn' = fmap (adjustExtPE k) ixfn
                exttp = case ifr of
                          Array pt shp' u ->
                            MemArray pt shp' u $
                            ReturnsNewBlock sp' 0 ixfn'
                          _ -> error "Impossible case reached in addResCtxInIfBody"
            return (res_acc ++ [r],
                    ext_acc ++ ext_ses,
                    ctx_acc ++ mem_ctx_r,
                    br_acc ++ [exttp],
                    k + i)

adjustNewBlockExistential :: ([BodyReturns], Int) -> BodyReturns -> ([BodyReturns], Int)
adjustNewBlockExistential (acc, k) (MemArray pt shp u (ReturnsNewBlock space _ ixfun)) =
  (MemArray pt shp u (ReturnsNewBlock space k ixfun) : acc, k + 1)
adjustNewBlockExistential (acc, k) x = (x : acc, k)

inspect :: TypeBase (ShapeBase (Ext SubExp)) u -> Maybe Space -> MemInfo (Ext SubExp) u MemReturn
inspect (Array pt shape u) space =
  let space' = fromMaybe DefaultSpace space
      bodyret = MemArray pt shape u $ ReturnsNewBlock space' 0 $
        IxFun.iota $ map convert $ shapeDims shape
  in bodyret
inspect (Prim pt) _ = MemPrim pt
inspect (Mem space) _ = MemMem space

convert :: Ext SubExp -> PrimExp (Ext VName)
convert (Ext i) = LeafExp (Ext i) int32
convert (Free v) = Free <$> primExpFromSubExp int32 v

adjustExtV :: Int -> Ext VName -> Ext VName
adjustExtV _ (Free v) = Free v
adjustExtV k (Ext i) = Ext (k + i)

adjustExtPE :: Int -> PrimExp (Ext VName) -> PrimExp (Ext VName)
adjustExtPE k = fmap (adjustExtV k)

mkSpaceOks :: (Mem tolore, LocalScope tolore m) =>
              Int -> Body tolore -> m [Maybe Space]
mkSpaceOks num_vals (Body _ stms res) =
  inScopeOf stms $
  mapM mkSpaceOK $ takeLast num_vals res
  where mkSpaceOK (Var v) = do
          v_info <- lookupMemInfo v
          case v_info of MemArray _ _ _ (ArrayIn mem _) -> do
                           mem_info <- lookupMemInfo mem
                           case mem_info of MemMem space -> return $ Just space
                                            _ -> return Nothing
                         _ -> return Nothing
        mkSpaceOK _ = return Nothing

allocInLoopForm :: (Allocable fromlore tolore,
                    Allocator tolore (AllocM fromlore tolore)) =>
                   LoopForm fromlore -> AllocM fromlore tolore (LoopForm tolore)
allocInLoopForm (WhileLoop v) = return $ WhileLoop v
allocInLoopForm (ForLoop i it n loopvars) =
  ForLoop i it n <$> mapM allocInLoopVar loopvars
  where allocInLoopVar (p,a) = do
          case paramType p of
            Array bt shape u -> do
              (mem, ixfun) <- lookupArraySummary $ traceWith "looking up" a
              dims <- map (primExpFromSubExp int32) . arrayDims <$> lookupType (traceWith "looking up 2" a)
              let ixfun' = IxFun.slice ixfun $
                           fullSliceNum dims [DimFix $ LeafExp i int32]
              return (p { paramAttr = MemArray bt shape u $ ArrayIn mem ixfun' }, a)
            Prim bt ->
              return (p { paramAttr = MemPrim bt }, a)
            Mem space ->
              return (p { paramAttr = MemMem space }, a)

class SizeSubst op where
  opSizeSubst :: PatternT attr -> op -> ChunkMap

instance SizeSubst () where
  opSizeSubst _ _ = mempty

instance SizeSubst op => SizeSubst (MemOp op) where
  opSizeSubst pat (Inner op) = opSizeSubst pat op
  opSizeSubst _ _ = mempty

sizeSubst :: SizeSubst (Op lore) => Stm lore -> ChunkMap
sizeSubst (Let pat _ (Op op)) = opSizeSubst pat op
sizeSubst _ = mempty

mkLetNamesB' :: (Op (Lore m) ~ MemOp inner,
                 MonadBinder m, ExpAttr (Lore m) ~ (),
                 Allocator (Lore m) (PatAllocM (Lore m))) =>
                ExpAttr (Lore m) -> [VName] -> Exp (Lore m) -> m (Stm (Lore m))
mkLetNamesB' attr names e = do
  scope <- askScope
  pat <- bindPatternWithAllocations scope names e
  return $ Let pat (defAux attr) e

mkLetNamesB'' :: (Op (Lore m) ~ MemOp inner, ExpAttr lore ~ (),
                   HasScope (Engine.Wise lore) m, Allocator lore (PatAllocM lore),
                   MonadBinder m, Engine.CanBeWise (Op lore)) =>
                 [VName] -> Exp (Engine.Wise lore)
              -> m (Stm (Engine.Wise lore))
mkLetNamesB'' names e = do
  scope <- Engine.removeScopeWisdom <$> askScope
  (pat, prestms) <- runPatAllocM (patternWithAllocations names $ Engine.removeExpWisdom e) scope
  mapM_ bindAllocStm prestms
  let pat' = Engine.addWisdomToPattern pat e
      attr = Engine.mkWiseExpAttr pat' () e
  return $ Let pat' (defAux attr) e

simplifiable :: (Engine.SimplifiableLore lore,
                 ExpAttr lore ~ (),
                 BodyAttr lore ~ (),
                 Op lore ~ MemOp inner,
                 Allocator lore (PatAllocM lore)) =>
                (inner -> Engine.SimpleM lore (Engine.OpWithWisdom inner, Stms (Engine.Wise lore)))
             -> SimpleOps lore
simplifiable simplifyInnerOp =
  SimpleOps mkExpAttrS' mkBodyS' mkLetNamesS' protectOp simplifyOp
  where mkExpAttrS' _ pat e =
          return $ Engine.mkWiseExpAttr pat () e

        mkBodyS' _ bnds res = return $ mkWiseBody () bnds res

        mkLetNamesS' vtable names e = do
          (pat', stms) <- runBinder $ bindPatternWithAllocations env names $
                          removeExpWisdom e
          return (mkWiseLetStm pat' (defAux ()) e, stms)
          where env = removeScopeWisdom $ ST.toScope vtable

        protectOp taken pat (Alloc size space) = Just $ do
          tbody <- resultBodyM [size]
          fbody <- resultBodyM [intConst Int64 0]
          size' <- letSubExp "hoisted_alloc_size" $
                   If taken tbody fbody $ IfAttr [MemPrim int64] IfFallback
          letBind_ pat $ Op $ Alloc size' space
        protectOp _ _ _ = Nothing

        simplifyOp (Alloc size space) =
          (,) <$> (Alloc <$> Engine.simplify size <*> pure space) <*> pure mempty
        simplifyOp (Inner k) = do (k', hoisted) <- simplifyInnerOp k
                                  return (Inner k', hoisted)

bindPatternWithAllocations :: (MonadBinder m,
                               ExpAttr lore ~ (),
                               Op (Lore m) ~ MemOp inner,
                               Allocator lore (PatAllocM lore)) =>
                              Scope lore -> [VName] -> Exp lore
                           -> m (Pattern lore)
bindPatternWithAllocations types names e = do
  (pat,prebnds) <- runPatAllocM (patternWithAllocations names e) types
  mapM_ bindAllocStm prebnds
  return pat

data ExpHint = NoHint
             | Hint IxFun Space

defaultExpHints :: (Monad m, Attributes lore) => Exp lore -> m [ExpHint]
defaultExpHints e = return $ replicate (expExtTypeSize e) NoHint
