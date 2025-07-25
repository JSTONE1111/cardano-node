{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- HLINT ignore "Use map" -}
{- HLINT ignore "Use map with tuple-section" -}

module Cardano.Logging.DocuGenerator (
  -- First call documentTracer for every tracer and then
  -- docuResultToText on all results
    documentTracer
  , documentTracer'
  , docuResultsToText
  , docuResultsToMetricsHelptext
  -- Callbacks
  , docTracer
  , docTracerDatapoint
  , docIt
  , addFiltered
  , addLimiter
  , addSilent
  , addDocumentedNamespace
  , DocuResult
  , DocTracer(..)
) where

import           Cardano.Logging.ConfigurationParser ()
import           Cardano.Logging.DocuGenerator.Tree
import           Cardano.Logging.DocuGenerator.Result (DocuResult (..))
import qualified Cardano.Logging.DocuGenerator.Result as DocuResult
import           Cardano.Logging.Types

import           Prelude hiding (lines, unlines)

import           Control.Monad (mfilter)
import           Control.Monad.IO.Class (MonadIO, liftIO)
import qualified Control.Tracer as TR
import           Data.Aeson (ToJSON)
import qualified Data.Aeson.Encode.Pretty as AE
import           Data.IORef (modifyIORef, newIORef, readIORef)
import           Data.List (find, groupBy, intersperse, isPrefixOf, nub, sortBy)
import qualified Data.Map.Strict as Map
import           Data.Maybe (fromJust, fromMaybe, mapMaybe)
import           Data.Text (split)
import           Data.Text as T (Text, empty, intercalate, lines, pack, stripPrefix, toLower,
                   unlines)
import           Data.Text.Internal.Builder (toLazyText)
import           Data.Text.Lazy (toStrict)
import           Data.Text.Lazy.Builder (Builder, fromString, fromText, singleton)

type InconsistencyWarning = Text

utf16CircledT :: Text
utf16CircledT = "\x24E3"

utf16CircledS :: Text
utf16CircledS = "\x24E2"

utf16CircledM :: Text
utf16CircledM = "\x24DC"

-- | Convenience function for adding a namespace prefix to a documented
addDocumentedNamespace  :: [Text] -> Documented a -> Documented a
addDocumentedNamespace  out (Documented list) =
  Documented $ map
    (\ dm@DocMsg {} -> dm {dmNamespace = nsReplacePrefix out (dmNamespace dm)})
    list

data DocTracer = DocTracer {
      dtTracerNames :: [[Text]]
    , dtSilent      :: [[Text]]
    , dtNoMetrics   :: [[Text]]
    , dtBuilderList :: [([Text], DocuResult)]
    , dtWarnings    :: [InconsistencyWarning]
} deriving (Show)

instance Semigroup DocTracer where
  dtl <> dtr = DocTracer
                 (dtTracerNames dtl <> dtTracerNames dtr)
                 (dtSilent dtl <> dtSilent dtr)
                 (dtNoMetrics dtl <> dtNoMetrics dtr)
                 (dtBuilderList dtl <> dtBuilderList dtr)
                 (dtWarnings dtl <> dtWarnings dtr)

documentTracer' :: forall a a1.
     MetaTrace a
  => (Trace IO a1 -> IO (Trace IO a))
  -> Trace IO a1
  -> IO DocTracer
documentTracer' hook tracer = do
    tr' <- hook tracer
    documentTracer tr'

-- This fuction calls document tracers and returns a DocTracer result
documentTracer :: forall a.
     MetaTrace a
  => Trace IO a
  -> IO DocTracer
documentTracer tracer = do
    DocCollector docRef <- documentTracersRun [tracer]
    items <- fmap Map.toList (liftIO (readIORef docRef))
    let sortedItems = sortBy
                        (\ (_,l) (_,r) -> compare (ldNamespace l) (ldNamespace r))
                        items
    let messageDocs = map (\(i, ld) -> case ldNamespace ld of
                                        (prn,pon) : _  -> (prn ++ pon, documentItem (i, ld))
                                        []             -> (["No ns"], documentItem (i, ld))) sortedItems
        metricsItems = map snd $ filter (not . Map.null . ldMetricsDoc . snd) sortedItems
        metricsDocs = documentMetrics metricsItems
        tracerName = case sortedItems of
                      ((_i, ld) : _) -> case ldNamespace ld of
                                          (prn, _pon) : _  -> prn
                                          []               -> []
                      []             -> []
        silent = case sortedItems of
                      ((_i, ld) : _) -> ldSilent ld
                      [] -> False
        hasNoMetrics = null metricsItems
        warnings = concatMap (\(i, ld) -> case ldNamespace ld of
                                            (_,_): _       -> warningItem (i, ld)
                                            []             -> (pack "No ns for " <> ldDoc ld) :
                                              warningItem (i, ld)) sortedItems
    pure $ DocTracer
            [tracerName]
            [tracerName | silent]
            [tracerName | hasNoMetrics]
            (messageDocs ++ metricsDocs)
            warnings

  where
    documentItem :: (Int, LogDoc) -> DocuResult
    documentItem (_idx, ld@LogDoc {..}) =
      case ldBackends of
        [DatapointBackend] -> DocuDatapoint $
                    mconcat $ intersperse (fromText "\n\n")
                      [ namespacesBuilder (nub ldNamespace)
                      , accentuated ldDoc
                      ]
        _ -> DocuTracer $
                    mconcat $ intersperse (fromText "\n\n")
                      [ namespacesBuilder (nub ldNamespace)
                      , accentuated ldDoc
                      , propertiesBuilder ld
                      , configBuilder ld
                      ]

    warningItem :: (Int, LogDoc) -> [InconsistencyWarning]
    warningItem (_idx, ld@LogDoc {..}) =
      case ldBackends of
        [DatapointBackend] -> namespacesWarning (nub ldNamespace) ld
        _ -> namespacesWarning (nub ldNamespace) ld
                ++ propertiesWarning ld

    documentMetrics :: [LogDoc] -> [([Text],DocuResult)]
    documentMetrics logDocs =
      let nameCommentNamespaceList =
            concatMap (\ld -> zip (Map.toList (ldMetricsDoc ld)) (repeat (ldNamespace ld))) logDocs
          sortedNameCommentNamespaceList =
            sortBy (\a b -> compare ((fst . fst) a) ((fst . fst) b)) nameCommentNamespaceList
          groupedNameCommentNamespaceList =
            groupBy (\a b -> (fst . fst) a == (fst . fst) b) sortedNameCommentNamespaceList
      in mapMaybe documentMetrics' groupedNameCommentNamespaceList

    documentMetrics' :: [( (Text, Text) , [([Text],[Text])] )] -> Maybe ([Text], DocuResult)
    documentMetrics' ncns@(((name, comment), _) : _tail) =
      Just ([name], DocuMetric
              $ mconcat $ intersperse (fromText "\n\n")
                    [ metricToBuilder (name,comment)
                    , namespacesMetricsBuilder (nub (concatMap snd ncns))
                    ])
    documentMetrics' [] = Nothing

    namespacesBuilder :: [([Text], [Text])] -> Builder
    namespacesBuilder [ns] = namespaceBuilder ns
    namespacesBuilder []   = fromText "__Warning__: namespace missing"
    namespacesBuilder nsl  =
      mconcat (intersperse (singleton '\n') (map namespaceBuilder nsl))

    namespaceBuilder :: ([Text], [Text]) -> Builder
    namespaceBuilder (nsPr, nsPo) = fromText "### " <>
      mconcat (intersperse (singleton '.') (map fromText (nsPr ++ nsPo)))

    namespacesMetricsBuilder :: [ ([Text], [Text])] -> Builder
    namespacesMetricsBuilder [ns] = fromText "Dispatched by: \n" <> namespaceMetricsBuilder ns
    namespacesMetricsBuilder []   = mempty
    namespacesMetricsBuilder nsl  = fromText "Dispatched by: \n" <>
      mconcat (intersperse (singleton '\n') (map namespaceMetricsBuilder nsl))

    namespaceMetricsBuilder :: ([Text], [Text]) -> Builder
    namespaceMetricsBuilder (nsPr, nsPo) = mconcat (intersperse (singleton '.')
                                                      (map fromText (nsPr ++ nsPo)))

    namespacesWarning :: [([Text], [Text])] -> LogDoc -> [InconsistencyWarning]
    namespacesWarning [] ld  = ["Namespace missing " <> ldDoc ld]
    namespacesWarning _ _  = []

    propertiesBuilder :: LogDoc -> Builder
    propertiesBuilder LogDoc {..} =
        case ldSeverityCoded of
          Just s  -> fromText "Severity:  " <> asCode (fromString (show s)) <> "\n"
          Nothing -> fromText "Severity missing: " <> "\n"
      <>
        case ldPrivacyCoded of
          Just p  -> fromText "Privacy:   " <> asCode (fromString (show p)) <> "\n"
          Nothing -> fromText "Privacy missing: " <> "\n"
      <>
        case ldDetailsCoded of
          Just d  -> fromText "Details:   " <> asCode (fromString (show d)) <> "\n"
          Nothing -> fromText "Details missing: " <> "\n"

    propertiesWarning :: LogDoc ->[InconsistencyWarning]
    propertiesWarning LogDoc {..} =
        case ldSeverityCoded of
          Just _s -> []
          Nothing -> map (\ns -> pack "Severity missing: " <> nsRawToText ns) ldNamespace
      <>
        case ldPrivacyCoded of
          Just _p -> []
          Nothing -> map (\ns -> pack "Privacy missing: " <> nsRawToText ns) ldNamespace
      <>
        case ldDetailsCoded of
          Just _d -> []
          Nothing -> map (\ns -> pack "Details missing: " <> nsRawToText ns) ldNamespace

    configBuilder :: LogDoc -> Builder
    configBuilder LogDoc {..} =
      fromText "From current configuration:\n"
      <> case nub ldDetails of
          []  -> mempty
          [d] -> if Just d /= ldDetailsCoded
                    then fromText "Details:   "
                            <> asCode (fromString (show d))
                    else mempty
          l   -> fromText "Details:   "
                  <> mconcat (intersperse (fromText ",\n      ")
                               (map (asCode . fromString . show) l))
      <> fromText "\n"
      <> backendsBuilder (nub ldBackends)
      <> fromText "\n"
      <> filteredBuilder (nub ldFiltered) ldSeverityCoded
      <> limiterBuilder (nub ldLimiter)

    backendsBuilder :: [BackendConfig] -> Builder
    backendsBuilder [] = fromText "No backends found"
    backendsBuilder l  = fromText "Backends:\n      "
                          <> mconcat (intersperse (fromText ",\n      ")
                                (map backendFormatToText l))

    backendFormatToText :: BackendConfig -> Builder
    backendFormatToText be = asCode (fromString (show be))

    filteredBuilder :: [SeverityF] -> Maybe SeverityS -> Builder
    filteredBuilder [] _ = mempty
    filteredBuilder _ Nothing = mempty
    filteredBuilder l (Just r) =
      fromText "Filtered "
      <> case l of
            [SeverityF (Just lh)] ->
              if fromEnum r >= fromEnum lh
                then (asCode . fromString) "Visible"
                else (asCode . fromString) "Invisible"
            [SeverityF Nothing] -> "Invisible"
            _ -> mempty
      <> fromText " by config value: "
      <> mconcat (intersperse (fromText ", ")
          (map (asCode . fromString . show) l))

    limiterBuilder ::
         [(Text, Double)]
      -> Builder
    limiterBuilder [] = mempty
    limiterBuilder l  =
      mconcat (intersperse (fromText ", ")
        (map (\ (n, d) ->  fromText "\nLimiter "
                        <> (asCode . fromText) n
                        <> fromText " with frequency "
                        <> (asCode . fromString. show) d)
              l))

    metricToBuilder :: (Text, Text) -> Builder
    metricToBuilder (name, text) =
        fromText "### "
          <> fromText name
            <> fromText "\n"
              <> accentuated text



-- | Calls the tracers in a documetation control mode,
-- and returns a DocCollector, from which the documentation gets generated
documentTracersRun :: forall a. MetaTrace a => [Trace IO a] -> IO DocCollector
documentTracersRun tracers = do
    let nss = allNamespaces :: [Namespace a]
        nsIdx = zip nss [0..]
    coll <- fmap DocCollector (liftIO $ newIORef (Map.empty :: Map.Map Int LogDoc))
    mapM_ (docTrace nsIdx coll) tracers
    pure coll
  where
    docTrace nsIdx dc@(DocCollector docRef) (Trace tr) =
      mapM_
        (\ (ns, idx) -> do
            let condDoc = documentFor ns
                doc = fromMaybe mempty condDoc

            modifyIORef docRef
                        (Map.insert
                          idx
                          ((emptyLogDoc
                              doc
                              (metricsDocFor ns))
                            { ldSeverityCoded = severityFor ns Nothing
                            , ldPrivacyCoded  = privacyFor ns Nothing
                            , ldDetailsCoded  = detailsFor ns Nothing
                          }))
            TR.traceWith tr (emptyLoggingContext {lcNSInner = nsInner ns},
                            Left (TCDocument idx dc)))
        nsIdx

-------------------- Callbacks ---------------------------

docTracer :: MonadIO m =>
     BackendConfig
  -> Trace m FormattedMessage
docTracer backendConfig = Trace $ TR.arrow $ TR.emit output
  where
    output p@(_, Left TCDocument {}) =
      docIt backendConfig p
    output (_, _) = pure ()

docTracerDatapoint :: MonadIO m =>
     BackendConfig
  -> Trace m a
docTracerDatapoint backendConfig = Trace $ TR.arrow $ TR.emit output
  where
    output p@(_, Left TCDocument {}) =
      docItDatapoint backendConfig p
    output (_, _) = pure ()


-- | Callback for doc collection
addFiltered :: MonadIO m => TraceControl -> Maybe SeverityF -> m ()
addFiltered (TCDocument idx (DocCollector docRef)) (Just sev) = do
  liftIO $ modifyIORef docRef (\ docMap ->
      Map.insert
        idx
        ((\e -> e { ldFiltered = seq sev (sev : ldFiltered e)})
          (case Map.lookup idx docMap of
                        Just e  -> e
                        Nothing -> error "DocuGenerator>>missing log doc"))
        docMap)
addFiltered _ _ = pure ()

-- | Callback for doc collection
addLimiter :: MonadIO m => TraceControl -> (Text, Double) -> m ()
addLimiter (TCDocument idx (DocCollector docRef)) (ln, lf) = do
  liftIO $ modifyIORef docRef (\ docMap ->
      Map.insert
        idx
        ((\e -> e { ldLimiter = seq ln (seq lf ((ln, lf) : ldLimiter e))})
          (case Map.lookup idx docMap of
                        Just e  -> e
                        Nothing -> error "DocuGenerator>>missing log doc"))
        docMap)
addLimiter _ _ = pure ()

addSilent :: MonadIO m => TraceControl -> Maybe Bool -> m ()
addSilent (TCDocument idx (DocCollector docRef)) (Just silent) = do
  liftIO $ modifyIORef docRef (\ docMap ->
      Map.insert
        idx
        ((\e -> e { ldSilent = silent})
          (case Map.lookup idx docMap of
                        Just e  -> e
                        Nothing -> error "DocuGenerator>>missing log doc"))
        docMap)
addSilent _ _ = pure ()

-- | Callback for doc collection
docIt :: MonadIO m
  => BackendConfig
  -> (LoggingContext, Either TraceControl a)
  -> m ()
docIt EKGBackend (LoggingContext{},
  Left (TCDocument idx (DocCollector docRef))) = do
    liftIO $ modifyIORef docRef (\ docMap ->
        Map.insert
          idx
          ((\e -> e { ldBackends  = EKGBackend : ldBackends e
                    })
            (case Map.lookup idx docMap of
                          Just e  -> e
                          Nothing -> error "DocuGenerator>>missing log doc"))
          docMap)
docIt backend (LoggingContext {..},
  Left (TCDocument idx (DocCollector docRef))) = do
    liftIO $ modifyIORef docRef (\ docMap ->
      Map.insert
        idx
        ((\e -> e { ldBackends  = backend : ldBackends e
                  , ldNamespace = nub ((lcNSPrefix,lcNSInner) : ldNamespace e)
                  , ldDetails   = case lcDetails of
                                    Nothing -> ldDetails e
                                    Just d  -> d : ldDetails e
                  })
          (case Map.lookup idx docMap of
                        Just e  -> e
                        Nothing -> error "DocuGenerator>>missing log doc"))
        docMap)
docIt _ (_, _) = pure ()

-- | Callback for doc collection
docItDatapoint :: MonadIO m =>
     BackendConfig
  -> (LoggingContext, Either TraceControl a)
  -> m ()
docItDatapoint _backend (LoggingContext {..},
  Left (TCDocument idx (DocCollector docRef))) = do
  liftIO $ modifyIORef docRef (\ docMap ->
      Map.insert
        idx
        ((\e -> e { ldNamespace = nub ((lcNSPrefix, lcNSInner) : ldNamespace e)
                  , ldBackends  = [DatapointBackend]
                  })
          (case Map.lookup idx docMap of
                        Just e  -> e
                        Nothing -> error "DocuGenerator>>missing log doc"))
        docMap)
docItDatapoint _backend (LoggingContext {}, _) = pure ()


-- Finally generate a text from all the builders
docuResultsToText :: DocTracer -> TraceConfig -> Text
docuResultsToText dt@DocTracer {..} configuration =
  let traceBuilders = sortBy (\ (l,_) (r,_) -> compare l r)
                          (filter (DocuResult.isTracer . snd) dtBuilderList)
      metricsBuilders = sortBy (\ (l,_) (r,_) -> compare l r)
                          (filter (DocuResult.isMetric .snd) dtBuilderList)
      datapointBuilders = sortBy (\ (l,_) (r,_) -> compare l r)
                          (filter (DocuResult.isDatapoint . snd) dtBuilderList)
      header  = fromText "# Cardano Trace Documentation\n\n"
      header1  = fromText "## Table Of Contents\n\n"
      toc      = generateTOC dt
                    (map fst traceBuilders)
                    (map fst metricsBuilders)
                    (map fst datapointBuilders)

      header2  = fromText "\n## Trace Messages\n\n"
      contentT = mconcat $ intersperse (fromText "\n\n")
                              (map (DocuResult.unpackDocu . snd) traceBuilders)
      header3  = fromText "\n## Metrics\n\n"
      contentM = mconcat $ intersperse (fromText "\n\n")
                              (map (DocuResult.unpackDocu . snd) metricsBuilders)
      header4  = fromText "\n## Datapoints\n\n"
      contentD = mconcat $ intersperse (fromText "\n\n")
                              (map (DocuResult.unpackDocu . snd) datapointBuilders)
      config  = fromText "\n## Configuration: \n```\n"
                        <> AE.encodePrettyToTextBuilder configuration
                        <> fromText "\n```\n"
      numbers = fromString $  show (length traceBuilders) <> " log messages, " <> "\n" <>
                              show (length metricsBuilders) <> " metrics," <> "\n" <>
                              show (length datapointBuilders) <> " datapoints." <> "\n\n"

      legend  = fromText $ utf16CircledT <> "- This is the root of a tracer\n\n" <>
                           utf16CircledS <> "- This is the root of a tracer that is silent because of the current configuration\n\n" <>
                           utf16CircledM <> "- This is the root of a tracer, that provides metrics\n\n" in
      toStrict $ toLazyText $
           header
        <> header1
        <> toc
        <> header2
        <> contentT
        <> header3
        <> contentM
        <> header4
        <> contentD
        <> config
        <> numbers
        <> legend

generateTOC :: DocTracer -> [[Text]] -> [[Text]] -> [[Text]] -> Builder
generateTOC DocTracer {..} traces metrics datapoints =
       generateTOCTraces
    <> generateTOCMetrics
    <> generateTOCDatapoints
    <> generateTOCRest
  where
    tracesTree = mapMaybe (trim []) (toForest traces)
    metricsTree = toForest (fmap splitToNS metrics)
    datapointsTree = toForest datapoints

    generateTOCTraces =
      fromText "### [Trace Messages](#trace-messages)\n\n"
      <> mconcat (map (namespaceToToc traces False []) tracesTree)
      <> fromText "\n"
    generateTOCMetrics =
      fromText "### [Metrics](#metrics)\n\n"
      <> mconcat (map (namespaceToToc (fmap splitToNS metrics) True []) metricsTree)
      <> fromText "\n"
    generateTOCDatapoints =
      fromText "### [Datapoints](#datapoints)\n\n"
      <> mconcat (map (namespaceToToc datapoints True []) datapointsTree)
      <> fromText "\n"
    generateTOCRest =
         fromText "### [Configuration](#configuration)\n\n"
      <> fromText "\n"

    splitToNS :: [Text] -> [Text]
    splitToNS [sym] = split (== '.') sym
    splitToNS other = other

    isTracerSymbol :: [Text] -> Bool
    isTracerSymbol tracer = tracer `elem` dtTracerNames

    -- Modify the given tracer tree so that the result is a tree where entries which
    -- are not tracers are removed. In case the whole tree doesn't contain a tracer, return Nothing.
    trim :: [Text] {- accumulated namespace in reverse -} -> Tree Text -> Maybe (Tree Text)
    trim ns (Node x nested) =
      let that = reverse (x : ns)
          -- List of all nested tracers that we shall render
          nestedTrimmed = mapMaybe (trim (x : ns)) nested in
      mfilter (\_ -> not (null nestedTrimmed) || isTracerSymbol that) (Just (Node x nestedTrimmed))

    namespaceToToc ::
         [[Text]]
      -> Bool
      -> [Text] {- Accumulated namespace in reverse -}
      -> Tree Text
      -> Builder
    namespaceToToc allTracers skipSymbols accns (Node x nested) = text
      where
        ns = reverse (x : accns)

        inner = mconcat (map (namespaceToToc allTracers skipSymbols (x : accns)) nested)

        indent lvl txt = mconcat (replicate lvl "\t") <> txt

        text :: Builder
        text =
          indent (length accns)
                 (
                      "1. "
                   <> "[" <> fromText x <> fromText symbolsText <> "]"
                   <> "(#" <> link <> ")\n"
                 ) <> inner

        symbolsText :: Text
        symbolsText = if skipSymbols then "" else
          let isTracer  = elem ns dtTracerNames
              isSilent  = elem ns dtSilent
              isMetric  = notElem ns dtNoMetrics
          in
              (if isTracer then utf16CircledT else "")
           <> (if isSilent then utf16CircledS else "")
           <> (if isMetric then utf16CircledM else "")

        -- The link to the description of the first tracer in that namespace
        link :: Builder
        link = mconcat (map (fromText . toLower) firstTracer)

        -- The first tracer in the list of tracers that has that namespace prefix
        firstTracer :: [Text]
        firstTracer = fromJust $ find (ns `isPrefixOf`) allTracers


asCode :: Builder -> Builder
asCode b = singleton '`' <> b <> singleton '`'

accentuated :: Text -> Builder
accentuated t = if t == ""
                  then fromText "\n"
                  else fromText "\n"
                        <> fromText (unlines $ map addAccent (lines t))
  where
    addAccent :: Text -> Text
    addAccent t' = if t' == ""
                    then ">"
                    else "> " <> t'

-- this reflects the type cardano-tracer expects the metrics help texts to be serialized from:
-- simple key-value map
newtype MetricsHelp = MH (Map.Map Text Text)
        deriving ToJSON via (Map.Map Text Text)

docuResultsToMetricsHelptext :: DocTracer -> Text
docuResultsToMetricsHelptext DocTracer{dtBuilderList} =
  toStrict $ toLazyText $
    AE.encodePrettyToTextBuilder' conf mh
  where
    conf = AE.defConfig { AE.confCompare = compare, AE.confTrailingNewline = True }
    mh = MH $ Map.fromList
      [(intercalate "." ns, fromMaybe T.empty x)
        | (ns, DocuMetric helpDescr) <- dtBuilderList

        -- for now, just extract the helptext (if any) from the markdown paragraph:
        -- it's the line that starts with "> "
        , let xs  = T.lines $ toStrict $ toLazyText helpDescr
        , let x   = mconcat $ map (stripPrefix "> ") xs
      ]
