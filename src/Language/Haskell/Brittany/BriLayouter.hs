#define INSERTTRACESGETSPACING 0
#define INSERTTRACESALT 0

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE TypeApplications #-}

module Language.Haskell.Brittany.BriLayouter
  ( layoutBriDoc
  )
where



#include "prelude.inc"

import qualified Language.Haskell.GHC.ExactPrint as ExactPrint
import qualified Language.Haskell.GHC.ExactPrint.Annotate as ExactPrint.Annotate
import qualified Language.Haskell.GHC.ExactPrint.Types as ExactPrint.Types
import qualified Language.Haskell.GHC.ExactPrint.Utils as ExactPrint.Utils

import           Language.Haskell.GHC.ExactPrint.Types ( AnnKey, Annotation )
import           Language.Haskell.Brittany.LayoutBasics
import           Language.Haskell.Brittany.Utils

import qualified Data.Text.Lazy.Builder as Text.Builder

import Language.Haskell.Brittany.Config.Types
import Language.Haskell.Brittany.Types

import           RdrName ( RdrName(..) )
import           GHC ( runGhc, GenLocated(L), moduleNameString )
import qualified Outputable    as GHC
import qualified DynFlags      as GHC
import qualified FastString    as GHC
import qualified SrcLoc        as GHC
import           SrcLoc ( SrcSpan )
import           OccName ( occNameString )
import           Name ( getOccString )
import           Module ( moduleName )
import           ApiAnnotation ( AnnKeywordId(..) )
import           Data.HList.ContainsType

import           Data.Data
import           Data.Generics.Schemes
import           Data.Generics.Aliases

import qualified Data.ByteString as B

import           DataTreePrint

import qualified Text.PrettyPrint as PP

import           Data.Function ( fix )

import           Control.Monad.Extra ( whenM )

import qualified Data.Generics.Uniplate.Direct as Uniplate
-- import qualified Data.Generics.Uniplate as Uniplate

import qualified Control.Monad.Memo as Memo

import qualified Control.Monad.Trans.Writer.Strict as WriterS



layoutBriDoc :: Data.Data.Data ast
             => ast
             -> BriDocNumbered
             -> PPM ()
layoutBriDoc ast briDoc = do
  -- first step: transform the briDoc.
  briDoc' <- MultiRWSS.withMultiStateS BDEmpty $ do
    traceIfDumpConf "bridoc raw" _dconf_dump_bridoc_raw
      $ briDocToDoc
      $ unwrapBriDocNumbered
      $ briDoc
    -- bridoc transformation: remove alts
    transformAlts briDoc >>= mSet
    mGet >>= traceIfDumpConf "bridoc post-alt" _dconf_dump_bridoc_simpl_alt . briDocToDoc
    -- bridoc transformation: float stuff in
    mGet <&> transformSimplifyFloating >>= mSet
    mGet >>= traceIfDumpConf "bridoc post-floating" _dconf_dump_bridoc_simpl_floating . briDocToDoc
    -- bridoc transformation: par removal
    mGet <&> transformSimplifyPar >>= mSet
    mGet >>= traceIfDumpConf "bridoc post-par" _dconf_dump_bridoc_simpl_par . briDocToDoc
    -- bridoc transformation: float stuff in
    mGet <&> transformSimplifyColumns >>= mSet
    mGet >>= traceIfDumpConf "bridoc post-columns" _dconf_dump_bridoc_simpl_columns . briDocToDoc
    -- -- bridoc transformation: indent
    mGet <&> transformSimplifyIndent >>= mSet
    mGet >>= traceIfDumpConf "bridoc post-indent" _dconf_dump_bridoc_simpl_indent . briDocToDoc
    mGet >>= traceIfDumpConf "bridoc final" _dconf_dump_bridoc_final . briDocToDoc
    -- -- convert to Simple type
    -- simpl <- mGet <&> transformToSimple
    -- return simpl
  
  anns :: ExactPrint.Types.Anns <- mAsk
  let filteredAnns = filterAnns ast anns
  
  let state = LayoutState
        { _lstate_baseY          = 0
        , _lstate_curYOrAddNewline = Right 0
        , _lstate_indLevel       = 0
        , _lstate_indLevelLinger = 0
        , _lstate_commentsPrior = extractCommentsPrior filteredAnns
        , _lstate_commentsPost  = extractCommentsPost  filteredAnns
        , _lstate_commentCol  = Nothing
        , _lstate_addSepSpace = Nothing
        , _lstate_inhibitMTEL = False
        }

  state' <- MultiRWSS.withMultiStateS state
          $ layoutBriDocM briDoc'
  
  let remainingComments = Map.elems (_lstate_commentsPrior state')
                       ++ Map.elems (_lstate_commentsPost  state')
  remainingComments `forM_` (mTell . (:[]) . LayoutErrorUnusedComment . show . fmap fst)
  
  return $ ()

data AltCurPos = AltCurPos
  { _acp_line :: Int -- chars in the current line
  , _acp_indent :: Int -- current indentation level
  , _acp_indentPrep :: Int -- indentChange affecting the next Par
  , _acp_forceMLFlag :: AltLineModeState
  }
  deriving (Show)

data AltLineModeState
  = AltLineModeStateNone
  | AltLineModeStateForceML Bool -- true ~ decays on next wrap
  | AltLineModeStateForceSL
  | AltLineModeStateContradiction
  -- i.e. ForceX False -> ForceX True -> None
  deriving (Show)

altLineModeDecay :: AltLineModeState -> AltLineModeState
altLineModeDecay AltLineModeStateNone = AltLineModeStateNone
altLineModeDecay (AltLineModeStateForceML False) = AltLineModeStateForceML True
altLineModeDecay (AltLineModeStateForceML True) = AltLineModeStateNone
altLineModeDecay AltLineModeStateForceSL = AltLineModeStateForceSL
altLineModeDecay AltLineModeStateContradiction = AltLineModeStateContradiction

altLineModeRefresh :: AltLineModeState -> AltLineModeState
altLineModeRefresh AltLineModeStateNone = AltLineModeStateNone
altLineModeRefresh AltLineModeStateForceML{} = AltLineModeStateForceML False
altLineModeRefresh AltLineModeStateForceSL = AltLineModeStateForceSL
altLineModeRefresh AltLineModeStateContradiction = AltLineModeStateContradiction

mergeLineMode :: AltCurPos -> AltLineModeState -> AltCurPos
mergeLineMode acp s = case (_acp_forceMLFlag acp, s) of
  (AltLineModeStateContradiction, _) -> acp
  (AltLineModeStateNone, x) -> acp { _acp_forceMLFlag = x }
  (AltLineModeStateForceSL, AltLineModeStateForceSL) -> acp
  (AltLineModeStateForceML{}, AltLineModeStateForceML{}) -> acp { _acp_forceMLFlag = s }
  _ -> acp { _acp_forceMLFlag = AltLineModeStateContradiction }

-- removes any BDAlt's from the BriDoc
transformAlts
  :: forall r w s
   . ( Data.HList.ContainsType.ContainsType Config r
     , Data.HList.ContainsType.ContainsType (Seq String) w
     )
  => BriDocNumbered
  -> MultiRWSS.MultiRWS r w s BriDoc
transformAlts briDoc
    = MultiRWSS.withMultiStateA
        (AltCurPos 0 0 0 AltLineModeStateNone)
    $ Memo.startEvalMemoT $ fmap unwrapBriDocNumbered $ rec $ briDoc
  where
    -- this funtion is exponential by nature and cannot be improved in any
    -- way i can think of, and if tried. (stupid StableNames.)
    -- transWrap :: BriDoc -> BriDocNumbered
    -- transWrap brDc = flip StateS.evalState (1::Int)
    --                $ Memo.startEvalMemoT
    --                $ go brDc
    --   where
    --     incGet = StateS.get >>= \i -> StateS.put (i+1) $> i
    --     go :: BriDoc -> Memo.MemoT BriDoc BriDocNumbered (StateS.State Int) BriDocNumbered
    --     go = Memo.memo $ \bdX -> do
    --       i <- lift $ incGet
    --       fmap (\bd' -> (i,bd')) $ case bdX of
    --         BDEmpty           -> return $ BDFEmpty
    --         BDLit t           -> return $ BDFLit t
    --         BDSeq list        -> BDFSeq <$> go `mapM` list
    --         BDCols sig list   -> BDFCols sig <$> go `mapM` list
    --         BDSeparator       -> return $ BDFSeparator
    --         BDAddBaseY ind bd -> BDFAddBaseY ind <$> go bd
    --         BDSetBaseY bd     -> BDFSetBaseY <$> go bd
    --         BDSetIndentLevel bd     -> BDFSetIndentLevel <$> go bd
    --         BDPar ind line indented -> [ BDFPar ind line' indented'
    --                                    | line' <- go line
    --                                    , indented' <- go indented
    --                                    ]
    --         BDAlt alts              -> BDFAlt <$> go `mapM` alts -- not that this will happen
    --         BDForceMultiline  bd    -> BDFForceMultiline <$> go bd
    --         BDForceSingleline bd    -> BDFForceSingleline <$> go bd
    --         BDForwardLineMode bd    -> BDFForwardLineMode <$> go bd
    --         BDExternal k ks c t         -> return $ BDFExternal k ks c t
    --         BDAnnotationPrior annKey bd -> BDFAnnotationPrior annKey <$> go bd
    --         BDAnnotationPost  annKey bd -> BDFAnnotationPost  annKey <$> go bd
    --         BDLines lines         -> BDFLines <$> go `mapM` lines
    --         BDEnsureIndent ind bd -> BDFEnsureIndent ind <$> go bd
    --         BDProhibitMTEL bd     -> BDFProhibitMTEL <$> go bd



    rec :: BriDocNumbered -> Memo.MemoT Int [VerticalSpacing] (MultiRWSS.MultiRWS r w (AltCurPos ': s)) BriDocNumbered
    rec bdX@(brDcId, brDc) = do
#if INSERTTRACESALT
      do
        acp :: AltCurPos <- mGet
        tellDebugMess $ "transformAlts: visiting: " ++ show (toConstr brDc, acp)
#endif
      let reWrap = (,) brDcId
      -- debugAcp :: AltCurPos <- mGet
      case brDc of
        -- BDWrapAnnKey annKey bd -> do
        --   acp <- mGet
        --   mSet $ acp { _acp_forceMLFlag = altLineModeDecay $ _acp_forceMLFlag acp }
        --   BDWrapAnnKey annKey <$> rec bd
        BDFEmpty{}    -> processSpacingSimple bdX $> bdX
        BDFLit{}      -> processSpacingSimple bdX $> bdX
        BDFSeq list      ->
          reWrap . BDFSeq <$> list `forM` rec
        BDFCols sig list ->
          reWrap . BDFCols sig <$> list `forM` rec
        BDFSeparator  -> processSpacingSimple bdX $> bdX
        BDFAddBaseY indent bd -> do
          acp <- mGet
          indAmount <- mAsk <&> _conf_layout .> _lconfig_indentAmount .> runIdentity
          let indAdd = case indent of
                BrIndentNone -> 0
                BrIndentRegular -> indAmount
                BrIndentSpecial i -> i
          mSet $ acp { _acp_indentPrep = max (_acp_indentPrep acp) indAdd }
          r <- rec bd
          acp' <- mGet
          mSet $ acp' { _acp_indent = _acp_indent acp }
          return $ case indent of
            BrIndentNone -> r
            BrIndentRegular ->   reWrap $ BDFAddBaseY (BrIndentSpecial indAdd) r
            BrIndentSpecial i -> reWrap $ BDFAddBaseY (BrIndentSpecial i) r
        BDFSetBaseY bd -> do
          acp <- mGet
          mSet $ acp { _acp_indent = _acp_line acp }
          r <- rec bd
          acp' <- mGet
          mSet $ acp' { _acp_indent = _acp_indent acp }
          return $ reWrap $ BDFSetBaseY r
        BDFSetIndentLevel bd -> do
          reWrap . BDFSetIndentLevel <$> rec bd
        BDFPar indent sameLine indented -> do
          indAmount <- mAsk <&> _conf_layout .> _lconfig_indentAmount .> runIdentity
          let indAdd = case indent of
                BrIndentNone -> 0
                BrIndentRegular -> indAmount
                BrIndentSpecial i -> i
          acp <- mGet
          let ind = _acp_indent acp + _acp_indentPrep acp + indAdd
          mSet $ acp
            { _acp_indent = ind
            , _acp_indentPrep = 0
            }
          sameLine' <- rec sameLine
          mModify $ \acp' -> acp'
            { _acp_line   = ind
            , _acp_indent = ind
            }
          indented' <- rec indented
          return $ reWrap $ BDFPar indent sameLine' indented'
        BDFAlt [] -> error "empty BDAlt" -- returning BDEmpty instead is a
                                        -- possibility, but i will prefer a
                                        -- fail-early approach; BDEmpty does not
                                        -- make sense semantically for Alt[].
        BDFAlt alts -> do
          altChooser <- mAsk <&> _conf_layout .> _lconfig_altChooser .> runIdentity
          case altChooser of
            AltChooserSimpleQuick -> do
              rec $ head alts
            AltChooserShallowBest -> do
              spacings <- alts `forM` getSpacing
              acp <- mGet
              let lineCheck LineModeInvalid = False
                  lineCheck (LineModeValid (VerticalSpacing _ p)) =
                    case _acp_forceMLFlag acp of
                      AltLineModeStateNone      -> True
                      AltLineModeStateForceSL{} -> p == VerticalSpacingParNone
                      AltLineModeStateForceML{} -> p /= VerticalSpacingParNone
                      AltLineModeStateContradiction -> False
                  lineCheck _ = error "ghc exhaustive check is insufficient"
              lconf <- _conf_layout <$> mAsk
#if INSERTTRACESALT
              tellDebugMess $ "considering options with " ++ show (length alts, acp)
#endif
              let options = -- trace ("considering options:" ++ show (length alts, acp)) $
                            (zip spacings alts
                             <&> \(vs, bd) -> -- trace ("spacing=" ++ show vs ++ ",hasSpace=" ++ show (hasSpace lconf acp vs) ++ ",lineCheck=" ++ show (lineCheck vs))
                               ( hasSpace1 lconf acp vs && lineCheck vs, bd))
#if INSERTTRACESALT
              zip spacings options `forM_` \(vs, (_, bd)) ->
                tellDebugMess $ "  " ++ "spacing=" ++ show vs
                             ++ ",hasSpace=" ++ show (hasSpace1 lconf acp vs)
                             ++ ",lineCheck=" ++ show (lineCheck vs)
                             ++ " " ++ show (toConstr bd)
#endif
              id -- $ (fmap $ \x -> traceShow (briDocToDoc x) x)
                 $ rec
                 $ fromMaybe (-- trace ("choosing last") $
                              List.last alts)
                 $ Data.List.Extra.firstJust (\(_i::Int, (b,x)) ->
                     [ -- traceShow ("choosing option " ++ show i) $
                       x
                     | b
                     ])
                 $ zip [1..] options
            AltChooserBoundedSearch limit -> do
              spacings <- alts `forM` getSpacings limit
              acp <- mGet
              let lineCheck (VerticalSpacing _ p) =
                    case _acp_forceMLFlag acp of
                      AltLineModeStateNone      -> True
                      AltLineModeStateForceSL{} -> p == VerticalSpacingParNone
                      AltLineModeStateForceML{} -> p /= VerticalSpacingParNone
                      AltLineModeStateContradiction -> False
              lconf <- _conf_layout <$> mAsk
#if INSERTTRACESALT
              tellDebugMess $ "considering options with " ++ show (length alts, acp)
#endif
              let options = -- trace ("considering options:" ++ show (length alts, acp)) $
                            (zip spacings alts
                             <&> \(vs, bd) -> -- trace ("spacing=" ++ show vs ++ ",hasSpace=" ++ show (hasSpace lconf acp vs) ++ ",lineCheck=" ++ show (lineCheck vs))
                               (  any (hasSpace2 lconf acp) vs
                               && any lineCheck vs, bd))
#if INSERTTRACESALT
              zip spacings options `forM_` \(vs, (_, bd)) ->
                tellDebugMess $ "  " ++ "spacing=" ++ show vs
                             ++ ",hasSpace=" ++ show (hasSpace2 lconf acp <$> vs)
                             ++ ",lineCheck=" ++ show (lineCheck <$> vs)
                             ++ " " ++ show (toConstr bd)
#endif
              id -- $ (fmap $ \x -> traceShow (briDocToDoc x) x)
                 $ rec
                 $ fromMaybe (-- trace ("choosing last") $
                              List.last alts)
                 $ Data.List.Extra.firstJust (\(_i::Int, (b,x)) ->
                     [ -- traceShow ("choosing option " ++ show i) $
                       x
                     | b
                     ])
                 $ zip [1..] options
        BDFForceMultiline bd -> do
          acp <- mGet
          x <- do
            mSet $ mergeLineMode acp (AltLineModeStateForceML False)
            rec bd
          acp' <- mGet
          mSet $ acp' { _acp_forceMLFlag = _acp_forceMLFlag acp }
          return $ x
        BDFForceSingleline bd -> do
          acp <- mGet
          x <- do
            mSet $ mergeLineMode acp AltLineModeStateForceSL
            rec bd
          acp' <- mGet
          mSet $ acp' { _acp_forceMLFlag = _acp_forceMLFlag acp }
          return $ x
        BDFForwardLineMode bd -> do
          acp <- mGet
          x <- do
            mSet $ acp { _acp_forceMLFlag = altLineModeRefresh $ _acp_forceMLFlag acp }
            rec bd
          acp' <- mGet
          mSet $ acp' { _acp_forceMLFlag = _acp_forceMLFlag acp }
          return $ x
        BDFExternal{} -> processSpacingSimple bdX $> bdX
        BDFAnnotationPrior annKey bd -> do
          acp <- mGet
          mSet $ acp { _acp_forceMLFlag = altLineModeDecay $ _acp_forceMLFlag acp }
          bd' <- rec bd
          return $ reWrap $ BDFAnnotationPrior annKey bd'
        BDFAnnotationPost annKey bd ->
          reWrap . BDFAnnotationPost annKey <$> rec bd
        BDFLines [] -> return $ reWrap BDFEmpty -- evil transformation. or harmless.
        BDFLines (l:lr) -> do
          ind <- _acp_indent <$> mGet
          l' <- rec l
          lr' <- lr `forM` \x -> do
            mModify $ \acp -> acp
              { _acp_line   = ind
              , _acp_indent = ind
              }
            rec x
          return $ reWrap $ BDFLines (l':lr')
        BDFEnsureIndent indent bd ->
          reWrap . BDFEnsureIndent indent <$> rec bd
        BDFNonBottomSpacing bd -> rec bd
        BDFProhibitMTEL bd ->
          reWrap . BDFProhibitMTEL <$> rec bd
    processSpacingSimple :: (MonadMultiReader
                                                     Config m,
                                                   MonadMultiState AltCurPos m, MonadMultiWriter (Seq String) m) => BriDocNumbered -> m ()
    processSpacingSimple bd = getSpacing bd >>= \case
      LineModeInvalid                           -> error "processSpacingSimple inv"
      LineModeValid (VerticalSpacing i VerticalSpacingParNone) -> do
        acp <- mGet
        mSet $ acp { _acp_line = _acp_line acp + i }
      LineModeValid (VerticalSpacing _ _)  -> error "processSpacingSimple par"
      _ -> error "ghc exhaustive check is insufficient"
    hasSpace1 :: LayoutConfig -> AltCurPos -> LineModeValidity VerticalSpacing -> Bool
    hasSpace1 _ _ LineModeInvalid = False
    hasSpace1 lconf acp (LineModeValid vs) = hasSpace2 lconf acp vs
    hasSpace1 _ _ _ = error "ghc exhaustive check is insufficient"
    hasSpace2 :: LayoutConfig -> AltCurPos -> VerticalSpacing -> Bool
    hasSpace2 lconf (AltCurPos line _indent _ _) (VerticalSpacing sameLine VerticalSpacingParNone)
      = line + sameLine <= runIdentity (_lconfig_cols lconf)
    hasSpace2 lconf (AltCurPos line indent indentPrep _) (VerticalSpacing sameLine (VerticalSpacingParSome par))
      = line + sameLine <= runIdentity (_lconfig_cols lconf)
        && indent + indentPrep + par <= runIdentity (_lconfig_cols lconf)
    hasSpace2 lconf (AltCurPos line _indent _ _) (VerticalSpacing sameLine VerticalSpacingParNonBottom)
      = line + sameLine <= runIdentity (_lconfig_cols lconf)

getSpacing :: forall m . (MonadMultiReader Config m, MonadMultiWriter (Seq String) m) => BriDocNumbered -> m (LineModeValidity VerticalSpacing)
getSpacing !bridoc = rec bridoc
 where
  rec :: BriDocNumbered -> m (LineModeValidity VerticalSpacing)
  rec (_, brDc) = do
    config <- mAsk
    result <- case brDc of
      -- BDWrapAnnKey _annKey bd -> rec bd
      BDFEmpty ->
        return $ LineModeValid $ VerticalSpacing 0 VerticalSpacingParNone
      BDFLit t ->
        return $ LineModeValid $ VerticalSpacing (Text.length t) VerticalSpacingParNone
      BDFSeq list ->
        sumVs <$> rec `mapM` list
      BDFCols _sig list -> sumVs <$> rec `mapM` list
      BDFSeparator ->
        return $ LineModeValid $ VerticalSpacing 1 VerticalSpacingParNone
      BDFAddBaseY indent bd -> do
        mVs <- rec bd
        return $ mVs <&> \vs -> vs
          { _vs_paragraph = case _vs_paragraph vs of
              VerticalSpacingParNone -> VerticalSpacingParNone
              VerticalSpacingParNonBottom -> VerticalSpacingParNonBottom
              VerticalSpacingParSome i -> VerticalSpacingParSome $ case indent of
                BrIndentNone      -> i
                BrIndentRegular   -> i + ( runIdentity
                                         $ _lconfig_indentAmount
                                         $ _conf_layout
                                         $ config
                                         )
                BrIndentSpecial j -> i + j
          }
      BDFSetBaseY bd -> do
        mVs <- rec bd
        return $ mVs <&> \vs -> vs
          -- We leave par as-is, even though it technically is not
          -- accurate (in general).
          -- the reason is that we really want to _keep_ it Just if it is
          -- just so we properly communicate the is-multiline fact.
          -- An alternative would be setting to (Just 0).
          { _vs_sameLine = max (_vs_sameLine vs)
                               (case _vs_paragraph vs of
                                  VerticalSpacingParNone -> 0
                                  VerticalSpacingParSome i -> i
                                  VerticalSpacingParNonBottom -> 999)
          , _vs_paragraph = VerticalSpacingParNonBottom
          }
      BDFSetIndentLevel bd -> rec bd
      BDFPar BrIndentNone sameLine indented -> do
        mVs <- rec sameLine
        indSp <- rec indented
        return $ [ VerticalSpacing lsp $ case mPsp of
                    VerticalSpacingParSome psp -> VerticalSpacingParSome $ max psp lineMax
                    VerticalSpacingParNone  -> VerticalSpacingParSome $ lineMax
                    VerticalSpacingParNonBottom -> VerticalSpacingParNonBottom
                 | VerticalSpacing lsp mPsp <- mVs
                 , lineMax <- getMaxVS $ indSp
                 ]
      BDFPar{} -> error "BDPar with indent in getSpacing"
      BDFAlt [] -> error "empty BDAlt"
      BDFAlt (alt:_) -> rec alt
      BDFForceMultiline  bd -> rec bd
      BDFForceSingleline bd -> do
        mVs <- rec bd
        return $ mVs >>= \(VerticalSpacing _ psp) ->
          case psp of
            VerticalSpacingParNone -> mVs
            _  -> LineModeInvalid
      BDFForwardLineMode bd -> rec bd
      BDFExternal{} ->
        return $ LineModeValid $ VerticalSpacing 999 VerticalSpacingParNone
      BDFAnnotationPrior _annKey bd -> rec bd
      BDFAnnotationPost  _annKey bd -> rec bd
      BDFLines [] -> return $ LineModeValid $ VerticalSpacing 0 VerticalSpacingParNone
      BDFLines ls@(_:_) -> do
        lSps@(mVs:_) <- rec `mapM` ls
        return $ [ VerticalSpacing lsp $ VerticalSpacingParSome $ lineMax
                 | VerticalSpacing lsp _ <- mVs
                 , lineMax <- getMaxVS $ maxVs $ lSps
                 ]
      BDFEnsureIndent indent bd -> do
        mVs <- rec bd
        let addInd = case indent of
              BrIndentNone      -> 0
              BrIndentRegular   -> runIdentity
                                 $ _lconfig_indentAmount
                                 $ _conf_layout
                                 $ config
              BrIndentSpecial i -> i
        return $ mVs <&> \(VerticalSpacing lsp psp) ->
          VerticalSpacing (lsp + addInd) psp
      BDFNonBottomSpacing bd -> do
        mVs <- rec bd
        return $ mVs <|> LineModeValid (VerticalSpacing 0 VerticalSpacingParNonBottom)
      BDFProhibitMTEL bd -> rec bd
#if INSERTTRACESGETSPACING
    mTell $ Seq.singleton ("getSpacing: visiting: "
                          ++ show (toConstr $ brDc)
                          ++ " -> "
                          ++ show result)
#endif
    return result
  maxVs :: [LineModeValidity VerticalSpacing] -> LineModeValidity VerticalSpacing
  maxVs = foldl'
    (liftM2 (\(VerticalSpacing x1 x2) (VerticalSpacing y1 y2) ->
        VerticalSpacing (max x1 y1) (case (x2, y2) of
          (x, VerticalSpacingParNone) -> x
          (VerticalSpacingParNone, x) -> x
          (_, VerticalSpacingParNonBottom) -> VerticalSpacingParNonBottom
          (VerticalSpacingParNonBottom, _) -> VerticalSpacingParNonBottom
          (VerticalSpacingParSome x, VerticalSpacingParSome y) -> VerticalSpacingParSome $ max x y)))
    (LineModeValid $ VerticalSpacing 0 VerticalSpacingParNone)
  sumVs :: [LineModeValidity VerticalSpacing] -> LineModeValidity VerticalSpacing
  sumVs = foldl'
    (liftM2 (\(VerticalSpacing x1 x2) (VerticalSpacing y1 y2) ->
        VerticalSpacing (x1 + y1) (case (x2, y2) of
          (x, VerticalSpacingParNone) -> x
          (VerticalSpacingParNone, x) -> x
          (_, VerticalSpacingParNonBottom) -> VerticalSpacingParNonBottom
          (VerticalSpacingParNonBottom, _) -> VerticalSpacingParNonBottom
          (VerticalSpacingParSome x, VerticalSpacingParSome y) -> VerticalSpacingParSome $ x + y)))
    (LineModeValid $ VerticalSpacing 0 VerticalSpacingParNone)
  getMaxVS :: LineModeValidity VerticalSpacing -> LineModeValidity Int
  getMaxVS = fmap $ \(VerticalSpacing x1 x2) -> x1 `max` case x2 of
    VerticalSpacingParSome i -> i
    VerticalSpacingParNone -> 0
    VerticalSpacingParNonBottom -> 999

getSpacings :: forall m . (MonadMultiReader Config m, MonadMultiWriter (Seq String) m)
  => Int -> BriDocNumbered -> Memo.MemoT Int [VerticalSpacing] m [VerticalSpacing]
getSpacings limit bridoc = rec bridoc
  where
    memoWithKey :: Memo.MonadMemo k v m1 => k -> m1 v -> m1 v
    memoWithKey k v = Memo.memo (const v) k
    rec :: BriDocNumbered -> Memo.MemoT Int [VerticalSpacing] m [VerticalSpacing]
    rec (bdKey, brdc) = memoWithKey bdKey $ do
      config <- mAsk
      let colMax = config & _conf_layout & _lconfig_cols & runIdentity
      let hasOkColCount (VerticalSpacing lsp psp) =
            lsp <= colMax && case psp of
              VerticalSpacingParNone -> True
              VerticalSpacingParSome i -> i <= colMax
              VerticalSpacingParNonBottom -> True
      let filterAndLimit :: [VerticalSpacing] -> [VerticalSpacing]
          filterAndLimit = forceList . take limit . filter hasOkColCount
          forceList l = foldl (flip seq) l l
      result <- case brdc of
        -- BDWrapAnnKey _annKey bd -> rec bd
        BDFEmpty ->
          return $ [VerticalSpacing 0 VerticalSpacingParNone]
        BDFLit t ->
          return $ [VerticalSpacing (Text.length t) VerticalSpacingParNone]
        BDFSeq list ->
          filterAndLimit . fmap sumVs . sequence <$> rec `mapM` list
        BDFCols _sig list ->
          filterAndLimit . fmap sumVs . sequence <$> rec `mapM` list
        BDFSeparator ->
          return $ [VerticalSpacing 1 VerticalSpacingParNone]
        BDFAddBaseY indent bd -> do
          mVs <- rec bd
          return $ mVs <&> \vs -> vs
            { _vs_paragraph = case _vs_paragraph vs of
                VerticalSpacingParNone -> VerticalSpacingParNone
                VerticalSpacingParNonBottom -> VerticalSpacingParNonBottom
                VerticalSpacingParSome i -> VerticalSpacingParSome $ case indent of
                  BrIndentNone      -> i
                  BrIndentRegular   -> i + ( runIdentity
                                           $ _lconfig_indentAmount
                                           $ _conf_layout
                                           $ config
                                           )
                  BrIndentSpecial j -> i + j
            }
        BDFSetBaseY bd -> do
          mVs <- rec bd
          return $ mVs <&> \vs -> vs
            -- We leave par as-is, even though it technically is not
            -- accurate (in general).
            -- the reason is that we really want to _keep_ it Just if it is
            -- just so we properly communicate the is-multiline fact.
            -- An alternative would be setting to (Just 0).
            { _vs_sameLine = max (_vs_sameLine vs)
                                 (case _vs_paragraph vs of
                                  VerticalSpacingParNone -> 0
                                  VerticalSpacingParSome i -> i
                                  VerticalSpacingParNonBottom -> 999)
            , _vs_paragraph = case _vs_paragraph vs of
                VerticalSpacingParNone -> VerticalSpacingParNone
                _ -> VerticalSpacingParNonBottom
            }
        BDFSetIndentLevel bd -> rec bd
        BDFPar BrIndentNone sameLine indented -> do
          mVss <- rec sameLine
          indSps <- rec indented
          let mVsIndSp = take limit
                       $ [ (x,y)
                         | x<-mVss
                         , y<-indSps
                         , hasOkColCount x
                         , hasOkColCount y
                         ]
          return $ mVsIndSp <&>
            \(VerticalSpacing lsp mPsp, indSp) ->
              VerticalSpacing lsp $ case mPsp of
                VerticalSpacingParSome psp ->
                  VerticalSpacingParSome $ max psp $ getMaxVS indSp -- TODO
                VerticalSpacingParNone -> spMakePar indSp
                VerticalSpacingParNonBottom -> VerticalSpacingParNonBottom
        BDFPar{} -> error "BDPar with indent in getSpacing"
        BDFAlt [] -> error "empty BDAlt"
        -- BDAlt (alt:_) -> rec alt
        BDFAlt alts -> filterAndLimit . join . transpose <$> rec `mapM` alts
        BDFForceMultiline  bd -> rec bd
        BDFForceSingleline bd -> do
          mVs <- rec bd
          return $ filter ((==VerticalSpacingParNone) . _vs_paragraph) mVs
        BDFForwardLineMode bd -> rec bd
        BDFExternal{} ->
          return $ [] -- yes, we just assume that we cannot properly layout
                      -- this.
        BDFAnnotationPrior _annKey bd -> rec bd
        BDFAnnotationPost  _annKey bd -> rec bd
        BDFLines [] -> return $ [VerticalSpacing 0 VerticalSpacingParNone]
        BDFLines ls@(_:_) -> do
          -- we simply assume that lines is only used "properly", i.e. in
          -- such a way that the first line can be treated "as a part of the
          -- paragraph". That most importantly means that Lines should never
          -- be inserted anywhere but at the start of the line. A
          -- counterexample would be anything like Seq[Lit "foo", Lines].
          lSpss <- rec `mapM` ls
          return $ filterAndLimit
                 $ transpose lSpss <&> \lSps ->
                     VerticalSpacing 0 (spMakePar $ maxVs lSps)
          -- lSpss@(mVs:_) <- rec `mapM` ls
          -- return $ case transpose lSpss of -- TODO: we currently only
          --                      -- consider the first alternative for the
          --                      -- line's spacings.
          --                      -- also i am not sure if always including
          --                      -- the first line length in the paragraph
          --                      -- length gives the desired results.
          --                      -- it is the safe path though, for now.
          --   []       -> []
          --   (lSps:_) -> mVs <&> \(VerticalSpacing lsp _) ->
          --     VerticalSpacing lsp $ VerticalSpacingParSome $ getMaxVS $ maxVs lSps
        BDFEnsureIndent indent bd -> do
          mVs <- rec bd
          let addInd = case indent of
                BrIndentNone      -> 0
                BrIndentRegular   -> runIdentity
                                   $ _lconfig_indentAmount
                                   $ _conf_layout
                                   $ config
                BrIndentSpecial i -> i
          return $ mVs <&> \(VerticalSpacing lsp psp) ->
            VerticalSpacing (lsp + addInd) psp
        BDFNonBottomSpacing bd -> do
          mVs <- rec bd
          return $ if null mVs
            then [VerticalSpacing 0 VerticalSpacingParNonBottom]
            else mVs <&> \vs -> vs { _vs_paragraph = VerticalSpacingParNonBottom}
        BDFProhibitMTEL bd -> rec bd
#if INSERTTRACESGETSPACING
      mTell $ Seq.fromList ["getSpacing: visiting: "
                            ++ show {-(toConstr $ brdc)-} (briDocToDoc $ unwrapBriDocNumbered (0, brdc))
                           , " -> "
                            ++ show result
                           ]
#endif
      return result
    maxVs :: [VerticalSpacing] -> VerticalSpacing
    maxVs = foldl'
      (\(VerticalSpacing x1 x2) (VerticalSpacing y1 y2) ->
          VerticalSpacing (max x1 y1) (case (x2, y2) of
            (x, VerticalSpacingParNone) -> x
            (VerticalSpacingParNone, x) -> x
            (_, VerticalSpacingParNonBottom) -> VerticalSpacingParNonBottom
            (VerticalSpacingParNonBottom, _) -> VerticalSpacingParNonBottom
            (VerticalSpacingParSome x, VerticalSpacingParSome y) -> VerticalSpacingParSome $ max x y))
      (VerticalSpacing 0 VerticalSpacingParNone)
    sumVs :: [VerticalSpacing] -> VerticalSpacing
    sumVs = foldl'
      (\(VerticalSpacing x1 x2) (VerticalSpacing y1 y2) ->
          VerticalSpacing (x1 + y1) (case (x2, y2) of
            (x, VerticalSpacingParNone) -> x
            (VerticalSpacingParNone, x) -> x
            (_, VerticalSpacingParNonBottom) -> VerticalSpacingParNonBottom
            (VerticalSpacingParNonBottom, _) -> VerticalSpacingParNonBottom
            (VerticalSpacingParSome x, VerticalSpacingParSome y) -> VerticalSpacingParSome $ x + y))
      (VerticalSpacing 0 VerticalSpacingParNone)
    getMaxVS :: VerticalSpacing -> Int
    getMaxVS (VerticalSpacing x1 x2) = x1 `max` case x2 of
      VerticalSpacingParSome i -> i
      VerticalSpacingParNone -> 0
      VerticalSpacingParNonBottom -> 999
    spMakePar :: VerticalSpacing -> VerticalSpacingPar
    spMakePar (VerticalSpacing x1 x2) = case x2 of
      VerticalSpacingParSome i -> VerticalSpacingParSome $ x1 `max` i
      VerticalSpacingParNone -> VerticalSpacingParSome $ x1
      VerticalSpacingParNonBottom -> VerticalSpacingParNonBottom


-- note that this is not total, and cannot be with that exact signature.
mergeIndents :: BrIndent -> BrIndent -> BrIndent
mergeIndents BrIndentNone x = x
mergeIndents x BrIndentNone = x
mergeIndents (BrIndentSpecial i) (BrIndentSpecial j) = BrIndentSpecial (max i j)
mergeIndents _ _ = error "mergeIndents"


-- TODO: move to uniplate upstream?
-- aka `transform`
transformUp  :: Uniplate.Uniplate on => (on -> on) -> (on -> on)
transformUp f = g where g = f . Uniplate.descend g
_transformDown :: Uniplate.Uniplate on => (on -> on) -> (on -> on)
_transformDown f = g where g = Uniplate.descend g . f
transformDownMay  :: Uniplate.Uniplate on => (on -> Maybe on) -> (on -> on)
transformDownMay f = g where g x = maybe x (Uniplate.descend g) $ f x
_transformDownRec  :: Uniplate.Uniplate on => (on -> Maybe on) -> (on -> on)
_transformDownRec f = g where g x = maybe (Uniplate.descend g x) g $ f x


transformSimplifyFloating :: BriDoc -> BriDoc
transformSimplifyFloating = stepBO .> stepFull
  -- note that semantically, stepFull is completely sufficient.
  -- but the bottom-up switch-to-top-down-on-match transformation has much
  -- better complexity.
  where
    descendPost = transformDownMay $ \case
      -- post floating in
      BDAnnotationPost annKey1 (BDPar ind line indented) ->
        Just $ BDPar ind line $ BDAnnotationPost annKey1 indented
      BDAnnotationPost annKey1 (BDSeq list) ->
        Just $ BDSeq $ List.init list ++ [BDAnnotationPost annKey1 $ List.last list]
      BDAnnotationPost annKey1 (BDLines list) ->
        Just $ BDLines $ List.init list ++ [BDAnnotationPost annKey1 $ List.last list]
      BDAnnotationPost annKey1 (BDCols sig cols) ->
        Just $ BDCols sig $ List.init cols ++ [BDAnnotationPost annKey1 $ List.last cols]
      BDAnnotationPost annKey1 (BDAddBaseY indent x) ->
        Just $ BDAddBaseY indent $ BDAnnotationPost annKey1 x
      _ -> Nothing
    descendPrior = transformDownMay $ \case
      -- prior floating in
      BDAnnotationPrior annKey1 (BDPar ind line indented) ->
         Just $ BDPar ind (BDAnnotationPrior annKey1 line) indented
      BDAnnotationPrior annKey1 (BDSeq (l:lr)) ->
         Just $ BDSeq (BDAnnotationPrior annKey1 l:lr)
      BDAnnotationPrior annKey1 (BDLines (l:lr)) ->
         Just $ BDLines (BDAnnotationPrior annKey1 l:lr)
      BDAnnotationPrior annKey1 (BDCols sig (l:lr)) ->
         Just $ BDCols sig (BDAnnotationPrior annKey1 l:lr)
      BDAnnotationPrior annKey1 (BDAddBaseY indent x) ->
         Just $ BDAddBaseY indent $ BDAnnotationPrior annKey1 x
      _ -> Nothing
    descendAddB = transformDownMay $ \case
      -- AddIndent floats into Lines.
      BDAddBaseY BrIndentNone x ->
        Just x
      BDAddBaseY indent (BDLines lines) ->
        Just $ BDLines $ BDAddBaseY indent <$> lines
      -- AddIndent floats into last column
      BDAddBaseY indent (BDCols sig cols) ->
        Just $ BDCols sig $ List.init cols ++ [BDAddBaseY indent $ List.last cols]
      -- merge AddIndent and Par
      BDAddBaseY ind1 (BDPar ind2 line indented) ->
        Just $ BDPar (mergeIndents ind1 ind2) line indented
      BDAddBaseY ind (BDAnnotationPrior annKey1 x) ->
        Just $ BDAnnotationPrior annKey1 (BDAddBaseY ind x)
      BDAddBaseY ind (BDAnnotationPost annKey1 x) ->
        Just $ BDAnnotationPost annKey1 (BDAddBaseY ind x)
      BDAddBaseY ind (BDSeq list) ->
        Just $ BDSeq $ List.init list ++ [BDAddBaseY ind (List.last list)]
      BDAddBaseY _ lit@BDLit{} ->
        Just $ lit
      _ -> Nothing
    stepBO :: BriDoc -> BriDoc
    stepBO = -- traceFunctionWith "stepBO" (show . briDocToDocWithAnns) (show . briDocToDocWithAnns) $
             transformUp f
      where
        f = \case
          x@BDAnnotationPrior{} -> descendPrior x
          x@BDAnnotationPost{}  -> descendPost  x
          x@BDAddBaseY{}        -> descendAddB  x
          x -> x
    stepFull = -- traceFunctionWith "stepFull" (show . briDocToDocWithAnns) (show . briDocToDocWithAnns) $
               Uniplate.rewrite $ \case
      -- AddIndent floats into Lines.
      BDAddBaseY BrIndentNone x ->
        Just $ x
      BDAddBaseY indent (BDLines lines) ->
        Just $ BDLines $ BDAddBaseY indent <$> lines
      -- AddIndent floats into last column
      BDAddBaseY indent (BDCols sig cols) ->
        Just $ BDCols sig $ List.init cols ++ [BDAddBaseY indent $ List.last cols]
      BDAddBaseY ind (BDSeq list) ->
        Just $ BDSeq $ List.init list ++ [BDAddBaseY ind (List.last list)]
      -- merge AddIndent and Par
      BDAddBaseY ind1 (BDPar ind2 line indented) ->
        Just $ BDPar (mergeIndents ind1 ind2) line indented
      BDAddBaseY _ lit@BDLit{} ->
        Just $ lit
      -- prior floating in
      BDAnnotationPrior annKey1 (BDPar ind line indented) ->
        Just $ BDPar ind (BDAnnotationPrior annKey1 line) indented
      BDAnnotationPrior annKey1 (BDSeq (l:lr)) ->
        Just $ BDSeq ((BDAnnotationPrior annKey1 l):lr)
      BDAnnotationPrior annKey1 (BDLines (l:lr)) ->
        Just $ BDLines ((BDAnnotationPrior annKey1 l):lr)
      BDAnnotationPrior annKey1 (BDCols sig (l:lr)) ->
        Just $ BDCols sig ((BDAnnotationPrior annKey1 l):lr)
      -- EnsureIndent float-in
      -- BDEnsureIndent indent (BDCols sig (col:colr)) ->
      --   Just $ BDCols sig (BDEnsureIndent indent col : (BDAddBaseY indent <$> colr))
      -- not sure if the following rule is necessary; tests currently are
      -- unaffected.
      BDEnsureIndent indent (BDLines lines) ->
        Just $ BDLines $ BDEnsureIndent indent <$> lines
      -- post floating in
      BDAnnotationPost annKey1 (BDPar ind line indented) ->
        Just $ BDPar ind line $ BDAnnotationPost annKey1 indented
      BDAnnotationPost annKey1 (BDSeq list) ->
        Just $ BDSeq $ List.init list ++ [BDAnnotationPost annKey1 $ List.last list]
      BDAnnotationPost annKey1 (BDLines list) ->
        Just $ BDLines $ List.init list ++ [BDAnnotationPost annKey1 $ List.last list]
      BDAnnotationPost annKey1 (BDCols sig cols) ->
        Just $ BDCols sig $ List.init cols ++ [BDAnnotationPost annKey1 $ List.last cols]
      _ -> Nothing

transformSimplifyPar :: BriDoc -> BriDoc
transformSimplifyPar = transformUp $ \case
  -- BDPar BrIndentNone line1 line2 -> Just $ BDLines [line1, line2]
  -- BDPar line indented ->
  --   Just $ BDLines [line, indented]
  -- BDPar ind1 (BDPar ind2 line p1) p2 | ind1==ind2 ->
  --   Just $ BDPar ind1 line (BDLines [p1, p2])
  x@(BDPar _ (BDPar _ BDPar{} _) _) -> x
  BDPar ind1 (BDPar ind2 line p1) (BDLines indenteds) ->
    BDPar ind1 line (BDLines (BDEnsureIndent ind2 p1: indenteds))
  BDPar ind1 (BDPar ind2 line p1) p2 ->
    BDPar ind1 line (BDLines [BDEnsureIndent ind2 p1, p2])
  BDLines lines | any (\case BDLines{} -> True
                             BDEmpty{} -> True
                             _ -> False) lines ->
    case go lines of
      [] -> BDEmpty
      [x] -> x
      xs -> BDLines xs
    where
      go = (=<<) $ \case
        BDLines l -> go l
        BDEmpty -> []
        x -> [x]
  BDLines []  -> BDEmpty
  BDLines [x] -> x
  -- BDCols sig cols | BDPar ind line indented <- List.last cols ->
  --   Just $ BDPar ind (BDCols sig (List.init cols ++ [line])) indented
  -- BDPar BrIndentNone line indented ->
  --   Just $ BDLines [line, indented]
  BDEnsureIndent BrIndentNone x -> x
  x -> x

isNotEmpty :: BriDoc -> Bool
isNotEmpty BDEmpty = False
isNotEmpty _       = True

transformSimplifyColumns :: BriDoc -> BriDoc
transformSimplifyColumns = Uniplate.rewrite $ \case
  -- BDWrapAnnKey annKey bd ->
  --   BDWrapAnnKey annKey $ transformSimplify bd
  BDEmpty -> Nothing
  BDLit{} -> Nothing
  BDSeq list | any (\case BDSeq{} -> True
                          BDEmpty{} -> True
                          _ -> False) list -> Just $ BDSeq $
    filter isNotEmpty list >>= \case
      BDSeq l -> l
      x -> [x]
  BDLines lines | any (\case BDLines{} -> True
                             BDEmpty{} -> True
                             _ -> False) lines ->
    Just $ BDLines $ filter isNotEmpty $ lines >>= \case
      BDLines l -> l
      x -> [x]
  -- prior floating in
  BDAnnotationPrior annKey1 (BDSeq (l:lr)) ->
    Just $ BDSeq (BDAnnotationPrior annKey1 l:lr)
  BDAnnotationPrior annKey1 (BDLines (l:lr)) ->
    Just $ BDLines (BDAnnotationPrior annKey1 l:lr)
  BDAnnotationPrior annKey1 (BDCols sig (l:lr)) ->
    Just $ BDCols sig (BDAnnotationPrior annKey1 l:lr)
  -- post floating in
  BDAnnotationPost annKey1 (BDSeq list) ->
    Just $ BDSeq $ List.init list ++ [BDAnnotationPost annKey1 $ List.last list]
  BDAnnotationPost annKey1 (BDLines list) ->
    Just $ BDLines $ List.init list ++ [BDAnnotationPost annKey1 $ List.last list]
  BDAnnotationPost annKey1 (BDCols sig cols) ->
    Just $ BDCols sig $ List.init cols ++ [BDAnnotationPost annKey1 $ List.last cols]
  -- ensureIndent float-in
  -- not sure if the following rule is necessary; tests currently are
  -- unaffected.
  BDEnsureIndent indent (BDLines lines) ->
    Just $ BDLines $ BDEnsureIndent indent <$> lines
  -- matching col special transformation
  BDCols sig1 cols1@(_:_)
    | BDLines lines@(_:_:_) <- List.last cols1
    , BDCols sig2 cols2 <- List.last lines
    , sig1==sig2 ->
        Just $ BDLines
          [ BDCols sig1 $ List.init cols1 ++ [BDLines $ List.init lines]
          , BDCols sig2 cols2
          ]
  BDCols sig1 cols1@(_:_)
    | BDLines lines@(_:_:_) <- List.last cols1
    , BDEnsureIndent _ (BDCols sig2 cols2) <- List.last lines
    , sig1==sig2 ->
        Just $ BDLines
          [ BDCols sig1 $ List.init cols1 ++ [BDLines $ List.init lines]
          , BDCols sig2 cols2
          ]
  BDPar ind col1@(BDCols sig1 _) col2@(BDCols sig2 _) | sig1==sig2 ->
    Just $ BDAddBaseY ind (BDLines [col1, col2])
  BDPar ind col1@(BDCols sig1 _) (BDLines (col2@(BDCols sig2 _):rest))
    | sig1==sig2 ->
    Just $ BDPar ind (BDLines [col1, col2]) (BDLines rest)
  BDPar ind (BDLines lines1) col2@(BDCols sig2 _)
    | BDCols sig1 _ <- List.last lines1
    , sig1==sig2 ->
    Just $ BDAddBaseY ind (BDLines $ lines1 ++ [col2])
  BDPar ind (BDLines lines1) (BDLines (col2@(BDCols sig2 _):rest))
    | BDCols sig1 _ <- List.last lines1
    , sig1==sig2 ->
    Just $ BDPar ind (BDLines $ lines1 ++ [col2]) (BDLines rest)
  -- BDPar ind1 (BDCols sig1 cols1) (BDPar ind2 line (BDCols sig2 cols2))
  --   | sig1==sig2 ->
  --       Just $ BDPar
  --         ind1
  --         (BDLines [BDCols sig1 cols1, BDCols sig])
  BDCols sig1 cols | BDPar _ind line (BDCols sig2 cols2) <- List.last cols
                   , sig1==sig2 ->
    Just $ BDLines
      [ BDCols sig1 (List.init cols ++ [line])
      , BDCols sig2 cols2
      ]
  BDCols sig1 cols | BDPar ind line (BDLines lines) <- List.last cols
                   , BDCols sig2 cols2 <- List.last lines
                   , sig1==sig2 ->
    Just $ BDLines
      [ BDCols sig1 $ List.init cols ++ [BDPar ind line (BDLines $ List.init lines)]
      , BDCols sig2 cols2
      ]
  BDLines [x]         -> Just $ x
  BDLines []          -> Just $ BDEmpty
  BDSeq{}             -> Nothing
  BDCols{}            -> Nothing
  BDSeparator         -> Nothing
  BDAddBaseY{}        -> Nothing
  BDSetBaseY{}        -> Nothing
  BDSetIndentLevel{}  -> Nothing
  BDPar{}             -> Nothing
  BDAlt{}             -> Nothing
  BDForceMultiline{}  -> Nothing
  BDForceSingleline{} -> Nothing
  BDForwardLineMode{} -> Nothing
  BDExternal{}        -> Nothing
  BDLines{}           -> Nothing
  BDAnnotationPrior{} -> Nothing
  BDAnnotationPost{}  -> Nothing
  BDEnsureIndent{}    -> Nothing
  BDProhibitMTEL{}    -> Nothing
  BDNonBottomSpacing x -> Just x

-- prepare layouting by translating BDPar's, replacing them with Indents and
-- floating those in. This gives a more clear picture of what exactly is
-- affected by what amount of indentation.
transformSimplifyIndent :: BriDoc -> BriDoc
transformSimplifyIndent = Uniplate.rewrite $ \case
  BDPar ind (BDLines lines) indented ->
    Just $ BDEnsureIndent ind $ BDLines $ lines ++ [indented]
  BDPar ind (BDCols sig cols) indented ->
    Just $ BDCols sig (List.init cols ++ [BDPar ind (List.last cols) indented])
  BDPar ind x indented ->
    Just $ BDLines
      [ BDAddBaseY ind x
      , BDEnsureIndent ind indented
      ]
  BDLines lines | any (\case BDLines{} -> True
                             BDEmpty{} -> True
                             _ -> False) lines ->
    Just $ BDLines $ filter isNotEmpty $ lines >>= \case
      BDLines l -> l
      x -> [x]
  BDAddBaseY i (BDAnnotationPost k x)  ->
    Just $ BDAnnotationPost k (BDAddBaseY i x)
  BDAddBaseY i (BDAnnotationPrior k x) ->
    Just $ BDAnnotationPrior k (BDAddBaseY i x)
  BDAddBaseY i (BDSeq l) ->
    Just $ BDSeq $ List.init l ++ [BDAddBaseY i $ List.last l]
  BDAddBaseY i (BDCols sig l) ->
    Just $ BDCols sig $ List.init l ++ [BDAddBaseY i $ List.last l]
  BDAddBaseY _ lit@BDLit{} ->
    Just lit

  _ -> Nothing


briDocLineLength :: BriDoc -> Int
briDocLineLength briDoc = flip StateS.evalState False $ rec briDoc
                          -- the state encodes whether a separate was already
                          -- appended at the current position.
 where
  rec = \case
    BDEmpty -> return $ 0
    BDLit t -> StateS.put False $> Text.length t
    BDSeq    bds -> sum <$> rec `mapM` bds
    BDCols _ bds -> sum <$> rec `mapM` bds
    BDSeparator -> StateS.get >>= \b -> StateS.put True $> if b then 0 else 1
    BDAddBaseY _ bd -> rec bd
    BDSetBaseY bd -> rec bd
    BDSetIndentLevel bd -> rec bd
    BDPar _ line _ -> rec line
    BDAlt{} -> error "briDocLineLength BDAlt"
    BDForceMultiline  bd -> rec bd
    BDForceSingleline bd -> rec bd
    BDForwardLineMode bd -> rec bd
    BDExternal _ _ _ t -> return $ Text.length t
    BDAnnotationPrior _ bd -> rec bd
    BDAnnotationPost  _ bd -> rec bd
    BDLines (l:_) -> rec l
    BDLines [] -> error "briDocLineLength BDLines []"
    BDEnsureIndent _ bd -> rec bd
    BDProhibitMTEL bd -> rec bd
    BDNonBottomSpacing bd -> rec bd

layoutBriDocM
  :: forall w m
   . ( m ~ MultiRWSS.MultiRWST
             '[Config, ExactPrint.Types.Anns]
             w
             '[LayoutState]
             Identity
     , ContainsType Text.Builder.Builder w
     , ContainsType [LayoutError] w
     , ContainsType (Seq String) w
     )
  => BriDoc
  -> m ()
layoutBriDocM = \case
  BDEmpty -> do
    return () -- can it be that simple
  BDLit t -> do
    layoutIndentRestorePostComment
    layoutRemoveIndentLevelLinger
    layoutWriteAppend t
  BDSeq list -> do
    list `forM_` layoutBriDocM
  -- in this situation, there is nothing to do about cols.
  -- i think this one does not happen anymore with the current simplifications.
  -- BDCols cSig list | BDPar sameLine lines <- List.last list ->
  --   alignColsPar $ BDCols cSig (List.init list ++ [sameLine]) : lines
  BDCols _ list -> do
    list `forM_` layoutBriDocM
  BDSeparator -> do
    layoutAddSepSpace
  BDAddBaseY indent bd -> do
    let indentF = case indent of
          BrIndentNone      -> id
          BrIndentRegular   -> layoutWithAddBaseCol
          BrIndentSpecial i -> layoutWithAddBaseColN i
    indentF $ layoutBriDocM bd
  BDSetBaseY bd -> do
    layoutSetBaseColCur $ layoutBriDocM bd
  BDSetIndentLevel bd -> do
    layoutSetIndentLevel $ layoutBriDocM bd
  BDEnsureIndent indent bd -> do
    let indentF = case indent of
          BrIndentNone      -> id
          BrIndentRegular   -> layoutWithAddBaseCol
          BrIndentSpecial i -> layoutWithAddBaseColN i
    indentF $ do
      layoutWriteEnsureBlock
      layoutBriDocM bd
  BDPar indent sameLine indented -> do
    layoutBriDocM sameLine
    let indentF = case indent of
          BrIndentNone      -> id
          BrIndentRegular   -> layoutWithAddBaseCol
          BrIndentSpecial i -> layoutWithAddBaseColN i
    indentF $ do
      layoutWriteNewlineBlock
      layoutBriDocM indented
  BDLines lines ->
    alignColsLines lines
  BDAlt [] -> error "empty BDAlt"
  BDAlt (alt:_) -> layoutBriDocM alt
  BDForceMultiline  bd -> layoutBriDocM bd
  BDForceSingleline bd -> layoutBriDocM bd
  BDForwardLineMode bd -> layoutBriDocM bd
  BDExternal annKey subKeys shouldAddComment t -> do
    let tlines = Text.lines $ t <> Text.pack "\n"
        tlineCount = length tlines
    anns :: ExactPrint.Types.Anns <- mAsk
    when shouldAddComment $ do
      layoutWriteAppend $ Text.pack $ "{-" ++ show (annKey, Map.lookup annKey anns) ++ "-}"
    zip [1..] tlines `forM_` \(i, l) -> do
      layoutWriteAppend $ l
      unless (i==tlineCount) layoutWriteNewlineBlock
    do
      state <- mGet
      let filterF k _ = not $ k `Set.member` subKeys
      mSet $ state
        { _lstate_commentsPrior = Map.filterWithKey filterF
                                $ _lstate_commentsPrior state
        , _lstate_commentsPost  = Map.filterWithKey filterF
                                $ _lstate_commentsPost  state
        }
  BDAnnotationPrior annKey bd -> do
    do
      state <- mGet
      let m   = _lstate_commentsPrior state
      let allowMTEL = not (_lstate_inhibitMTEL state)
                   && Data.Either.isRight (_lstate_curYOrAddNewline state)
      mAnn <- do
        let mAnn = Map.lookup annKey m
        mSet $ state { _lstate_commentsPrior = Map.delete annKey m }
        return mAnn
      case mAnn of
        Nothing -> when allowMTEL $ moveToExactAnn annKey
        Just [] -> when allowMTEL $ moveToExactAnn annKey
        Just priors -> do
          -- layoutResetSepSpace
          priors `forM_` \( ExactPrint.Types.Comment comment _ _
                          , ExactPrint.Types.DP (y, x)
                          ) -> do
            layoutMoveToCommentPos y x
            -- fixedX <- fixMoveToLineByIsNewline x
            -- replicateM_ fixedX layoutWriteNewline
            -- layoutMoveToIndentCol y
            layoutWriteAppendMultiline $ Text.pack $ comment
            -- mModify $ \s -> s { _lstate_curYOrAddNewline = Right 0 }
          when allowMTEL $ moveToExactAnn annKey
    layoutBriDocM bd
  BDAnnotationPost annKey bd -> do
    layoutBriDocM bd
    do
      mAnn <- do
        state <- mGet
        let m   = _lstate_commentsPost state
        let mAnn = Map.lookup annKey m
        mSet $ state { _lstate_commentsPost = Map.delete annKey m }
        return mAnn
      case mAnn of
        Nothing -> return ()
        Just posts -> do
          posts `forM_` \( ExactPrint.Types.Comment comment _ _
                          , ExactPrint.Types.DP (x, y)
                          ) -> do
            layoutMoveToCommentPos x y
            -- fixedX <- fixMoveToLineByIsNewline x
            -- replicateM_ fixedX layoutWriteNewline
            -- layoutMoveToIndentCol y
            layoutWriteAppendMultiline $ Text.pack $ comment
            -- mModify $ \s -> s { _lstate_curYOrAddNewline = Right 0 }
  BDNonBottomSpacing bd -> layoutBriDocM bd
  BDProhibitMTEL bd -> do
    -- set flag to True for this child, but disable afterwards.
    -- two hard aspects
    -- 1) nesting should be allowed. this means that resetting at the end must
    --    not indiscriminantely set to False, but take into account the
    --    previous value
    -- 2) nonetheless, newlines cancel inhibition. this means that if we ever
    --    find the flag set to False afterwards, we must not return it to
    --    the previous value, which might be True in the case of testing; it
    --    must remain False.
    state <- mGet
    mSet $ state { _lstate_inhibitMTEL = True }
    layoutBriDocM bd
    state' <- mGet
    when (_lstate_inhibitMTEL state') $ do
      mSet $ state' { _lstate_inhibitMTEL = _lstate_inhibitMTEL state }
  where
    -- alignColsPar :: [BriDoc]
    --           -> m ()
    -- alignColsPar l = colInfos `forM_` \colInfo -> do
    --     layoutWriteNewlineBlock
    --     processInfo (_cbs_map finalState) colInfo
    --   where
    --     (colInfos, finalState) = StateS.runState (mergeBriDocs l) (ColBuildState IntMapS.empty 0)
    alignColsLines :: [BriDoc]
              -> m ()
    alignColsLines l = do -- colInfos `forM_` \colInfo -> do
      colMax <- mAsk <&> _conf_layout .> _lconfig_cols .> runIdentity
      sequence_ $ List.intersperse layoutWriteEnsureNewlineBlock $ colInfos <&> processInfo colMax (_cbs_map finalState)
      where
        (colInfos, finalState) = StateS.runState (mergeBriDocs l) (ColBuildState IntMapS.empty 0)
    briDocToColInfo :: BriDoc -> StateS.State ColBuildState ColInfo
    briDocToColInfo = \case
      BDCols sig list -> withAlloc $ \ind -> do
        subInfos <- mapM briDocToColInfo list
        let lengths = briDocLineLength <$> list
        return $ (lengths, ColInfo ind sig (zip lengths subInfos))
      bd -> return $ ColInfoNo bd

    mergeBriDocs :: [BriDoc] -> StateS.State ColBuildState [ColInfo]
    mergeBriDocs bds = mergeBriDocsW ColInfoStart bds

    mergeBriDocsW :: ColInfo -> [BriDoc] -> StateS.State ColBuildState [ColInfo]
    mergeBriDocsW _ [] = return []
    mergeBriDocsW lastInfo (bd:bdr) = do
      info <- mergeInfoBriDoc lastInfo bd
      infor <- mergeBriDocsW info bdr
      return $ info : infor

    mergeInfoBriDoc :: ColInfo
                    -> BriDoc
                    -> StateS.StateT ColBuildState Identity ColInfo
    mergeInfoBriDoc ColInfoStart = briDocToColInfo
    mergeInfoBriDoc ColInfoNo{}  = briDocToColInfo
    mergeInfoBriDoc (ColInfo infoInd infoSig subLengthsInfos) = \case
      bd@(BDCols colSig subDocs)
        | infoSig == colSig
        && length subLengthsInfos == length subDocs -> do
          infos <- zip (snd <$> subLengthsInfos) subDocs
            `forM` uncurry mergeInfoBriDoc
          let curLengths = briDocLineLength <$> subDocs
          do -- update map
            s <- StateS.get
            let m = _cbs_map s
            let (Just spaces) = IntMapS.lookup infoInd m
            StateS.put s
              { _cbs_map = IntMapS.insert infoInd
                                          (zipWith max spaces curLengths)
                                          m
              }
          return $ ColInfo infoInd colSig (zip curLengths infos)
        | otherwise -> briDocToColInfo bd
      bd            -> return $ ColInfoNo bd
    
    withAlloc :: (ColIndex -> StateS.State ColBuildState (ColSpace, ColInfo))
              -> StateS.State ColBuildState ColInfo
    withAlloc f = do
      cbs <- StateS.get
      let ind = _cbs_index cbs
      StateS.put $ cbs { _cbs_index = ind + 1 }
      (space, info) <- f ind
      StateS.get >>= \c -> StateS.put
        $ c { _cbs_map = IntMapS.insert ind space $ _cbs_map c }
      return info

    processInfo :: Int -> ColMap -> ColInfo -> m ()
    processInfo colMax m = \case
      ColInfoStart -> error "should not happen (TM)"
      ColInfoNo doc -> layoutBriDocM doc
      ColInfo ind _ list -> do
        curX <- do
          state <- mGet
          return $ either id (const 0) (_lstate_curYOrAddNewline state)
                 + fromMaybe 0 (_lstate_addSepSpace state)
        -- tellDebugMess $ show curX
        let Just cols = IntMapS.lookup ind m
        let (maxX, posXs) = (mapAccumL (\acc x -> (acc+x,acc)) curX cols)
        -- handle the cases that the vertical alignment leads to more than max
        -- cols:
        -- this is not a full fix, and we must correct individually in addition.
        -- because: the (at least) line with the largest element in the last
        -- column will always still overflow, because we just updated the column
        -- sizes in such a way that it works _if_ we have sizes (*factor)
        -- in each column. but in that line, in the last column, we will be
        -- forced to occupy the full vertical space, not reduced by any factor.
        let fixedPosXs = if maxX>colMax
              then let factor :: Float = fromIntegral (colMax - curX)
                                       / fromIntegral (maxX - curX)
                       offsets = (subtract curX) <$> posXs
                       fixed = offsets <&> fromIntegral .> (*factor) .> truncate
                   in  fixed <&> (+curX)
              else posXs
        -- fixing overflows, act II.
        if List.last fixedPosXs + fst (List.last list) > colMax
          then -- we are doomed. there is no space in the world for us.
               -- or our children.
            list `forM_` (snd .> processInfoIgnore)
            -- we COULD do some fancy put-as-much-to-the-right-as-possible
            -- here. could. dunno if that would look good even, though.
          else zip fixedPosXs list `forM_` \(destX, x) -> do
            layoutWriteEnsureAbsoluteN destX
            processInfo colMax m (snd x)
    processInfoIgnore :: ColInfo -> m ()
    processInfoIgnore = \case
      ColInfoStart -> error "should not happen (TM)"
      ColInfoNo doc -> layoutBriDocM doc
      ColInfo _ _ list -> list `forM_` (snd .> processInfoIgnore)


type ColIndex = Int
type ColSpace = [Int]
type ColMap = IntMapS.IntMap {- ColIndex -} ColSpace

data ColInfo
  = ColInfoStart -- start value to begin the mapAccumL.
  | ColInfoNo BriDoc
  | ColInfo ColIndex ColSig [(Int, ColInfo)]

data ColBuildState = ColBuildState
  { _cbs_map :: ColMap
  , _cbs_index :: ColIndex
  }
