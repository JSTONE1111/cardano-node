{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE StandaloneDeriving #-}

{-# OPTIONS_GHC -Wno-orphans #-}

module Cardano.Node.Tracing.StateRep
  ( AddedToCurrentChain(..)
  , InitChainSelection (..)
  , NodeState (..)
  , OpeningDbs (..)
  , Replays (..)
  , StartupState (..)
  , traceNodeStateChainDB
  , traceNodeStateStartup
  , traceNodeStateShutdown
  ) where

import           Cardano.Api (textShow)

import           Cardano.Logging
import           Cardano.Node.Handlers.Shutdown (ShutdownTrace)
import           Cardano.Node.Protocol.Types (SomeConsensusProtocol (..))
import qualified Cardano.Node.Startup as Startup
import           Cardano.Slotting.Slot (EpochNo, SlotNo (..), WithOrigin, withOrigin)
import           Cardano.Tracing.OrphanInstances.Network ()
import qualified Ouroboros.Consensus.Block.RealPoint as RP
import qualified Ouroboros.Consensus.Node.NetworkProtocolVersion as NPV
import qualified Ouroboros.Consensus.Storage.ChainDB as ChainDB
import           Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal
import qualified Ouroboros.Consensus.Storage.LedgerDB as LedgerDB
import qualified Ouroboros.Consensus.Storage.LedgerDB as LgrDb
import           Ouroboros.Network.Block (pointSlot)

import           Control.DeepSeq (NFData)
import           Data.Aeson hiding (Result(..))
import           Data.Text as T (Text, pack)
import           Data.Time.Clock
import           Data.Time.Clock.POSIX
import           GHC.Generics (Generic)

deriving instance FromJSON ChunkNo

deriving instance ToJSON ChunkNo

deriving instance NFData ChunkNo

data OpeningDbs
  = StartedOpeningImmutableDB
  | OpenedImmutableDB (WithOrigin SlotNo) ChunkNo
  | StartedOpeningVolatileDB
  | OpenedVolatileDB
  | StartedOpeningLgrDB
  | OpenedLgrDB
  deriving (Generic, FromJSON, ToJSON)

deriving instance (NFData OpeningDbs)

data Replays
  = ReplayFromGenesis
  | ReplayFromSnapshot SlotNo
  | ReplayedBlock      SlotNo (WithOrigin SlotNo) (WithOrigin SlotNo)
  deriving (Generic, FromJSON, ToJSON)

deriving instance (NFData Replays)

data InitChainSelection
  = InitChainStartedSelection
  | InitChainSelected
  deriving (Generic, FromJSON, ToJSON)

deriving instance (NFData InitChainSelection)

type SyncPercentage = Double

data AddedToCurrentChain
  = AddedToCurrentChain !EpochNo !SlotNo !SyncPercentage
  deriving (Generic, FromJSON, ToJSON)

deriving instance (NFData AddedToCurrentChain)

data StartupState
  = StartupSocketConfigError Text
  | StartupDBValidation
  | NetworkConfigUpdate
  | NetworkConfigUpdateError Text
  | NonP2PWarning
  | WarningDevelopmentNodeToNodeVersions [NPV.NodeToNodeVersion]
  | WarningDevelopmentNodeToClientVersions [NPV.NodeToClientVersion]
  deriving (Generic, FromJSON, ToJSON)

deriving instance (NFData StartupState)

-- | The representation of the current state of node.
--   All node states prior to tracing system going online are effectively invisible.
data NodeState
  = NodeTracingOnlineConfiguring
  | NodeTracingFailure String
  | NodeOpeningDbs OpeningDbs
  | NodeReplays Replays
  | NodeInitChainSelection InitChainSelection
  | NodeKernelOnline
  | NodeAddBlock AddedToCurrentChain
  | NodeStartup StartupState
  | NodeShutdown ShutdownTrace
  deriving (Generic, FromJSON, ToJSON)

deriving instance (NFData NodeState)

instance LogFormatting NodeState where
  forMachine _ = \case
    NodeOpeningDbs x -> mconcat
      [ "kind" .= String "NodeOpeningDbs",         "openingDb" .= toJSON x]
    NodeReplays x -> mconcat
      [ "kind" .= String "NodeReplays",            "replays"   .= toJSON x]
    NodeInitChainSelection x -> mconcat
      [ "kind" .= String "NodeInitChainSelection", "chainSel"  .= toJSON x]
    NodeKernelOnline -> mconcat
      [ "kind" .= String "NodeInitChainSelection"]
    NodeAddBlock x -> mconcat
      [ "kind" .= String "NodeAddBlock",           "addBlock"  .= toJSON x]
    NodeStartup x -> mconcat
      [ "kind" .= String "NodeStartup",            "startup"   .= toJSON x]
    NodeShutdown x -> mconcat
      [ "kind" .= String "NodeShutdown",           "shutdown"  .= toJSON x]
    NodeTracingFailure x -> mconcat
      [ "kind" .= String "NodeTracingFailure",     "message"   .= toJSON x]
    _ -> mempty

  forHuman (NodeTracingFailure errMsg) = T.pack errMsg
  forHuman _ = ""


instance MetaTrace NodeState where
  namespaceFor NodeTracingOnlineConfiguring {}  =
    Namespace [] ["NodeTracingOnlineConfiguring"]
  namespaceFor NodeTracingFailure {}  =
    Namespace [] ["NodeTracingFailure"]
  namespaceFor NodeOpeningDbs {}  =
    Namespace [] ["OpeningDbs"]
  namespaceFor NodeReplays {}  =
    Namespace [] ["NodeReplays"]
  namespaceFor NodeInitChainSelection {}  =
    Namespace [] ["NodeInitChainSelection"]
  namespaceFor NodeKernelOnline {}  =
    Namespace [] ["NodeKernelOnline"]
  namespaceFor NodeAddBlock {}  =
    Namespace [] ["NodeAddBlock"]
  namespaceFor NodeStartup {}  =
    Namespace [] ["NodeStartup"]
  namespaceFor NodeShutdown {}  =
    Namespace [] ["NodeShutdown"]

  severityFor  (Namespace _ ["NodeTracingOnlineConfiguring"]) _ =
    Just Info
  severityFor  (Namespace _ ["NodeTracingFailure"]) _ =
    Just Error
  severityFor  (Namespace _ ["OpeningDbs"]) _ =
    Just Info
  severityFor  (Namespace _ ["NodeReplays"]) _ =
    Just Notice
  severityFor  (Namespace _ ["NodeInitChainSelection"]) _ =
    Just Notice
  severityFor  (Namespace _ ["NodeKernelOnline"]) _ =
    Just Info
  severityFor  (Namespace _ ["NodeAddBlock"]) _ =
    Just Notice
  severityFor  (Namespace _ ["NodeStartup"]) _ =
    Just Info
  severityFor  (Namespace _ ["NodeShutdown"]) _ =
    Just Warning
  severityFor _ns _ =
    Nothing

  documentFor  (Namespace _ ["NodeTracingOnlineConfiguring"]) = Just
    "Tracing system came online, system configuring now"
  documentFor  (Namespace _ ["NodeTracingFailure"]) = Just
    "Tracing system experienced a non-fatal failure during startup"
  documentFor  (Namespace _ ["OpeningDbs"]) = Just
    "ChainDB components being opened"
  documentFor  (Namespace _ ["NodeReplays"]) = Just
    "Replaying chain"
  documentFor  (Namespace _ ["NodeInitChainSelection"]) = Just
    "Performing initial chain selection"
  documentFor  (Namespace _ ["NodeKernelOnline"]) = Just
    ""
  documentFor  (Namespace _ ["NodeAddBlock"]) = Just
   "Applying block"
  documentFor  (Namespace _ ["NodeStartup"]) = Just
    "Node startup"
  documentFor  (Namespace _ ["NodeShutdown"]) = Just
    "Node shutting down"
  documentFor _ns = Nothing

  allNamespaces = [
          Namespace [] ["NodeTracingOnlineConfiguring"]
        , Namespace [] ["NodeTracingFailure"]
        , Namespace [] ["OpeningDbs"]
        , Namespace [] ["NodeReplays"]
        , Namespace [] ["NodeInitChainSelection"]
        , Namespace [] ["NodeKernelOnline"]
        , Namespace [] ["NodeAddBlock"]
        , Namespace [] ["NodeStartup"]
        , Namespace [] ["NodeShutdown"]
        ]


traceNodeStateChainDB
  :: SomeConsensusProtocol
  -> Trace IO NodeState
  -> ChainDB.TraceEvent blk
  -> IO ()
traceNodeStateChainDB _scp tr ev =
  case ev of
    ChainDB.TraceOpenEvent ev' ->
      case ev' of
        ChainDB.StartedOpeningImmutableDB ->
          traceWith tr $ NodeOpeningDbs StartedOpeningImmutableDB
        ChainDB.OpenedImmutableDB p chunk ->
          traceWith tr $ NodeOpeningDbs $ OpenedImmutableDB (pointSlot p) chunk
        ChainDB.StartedOpeningVolatileDB ->
          traceWith tr $ NodeOpeningDbs StartedOpeningVolatileDB
        ChainDB.OpenedVolatileDB {} ->
          traceWith tr $ NodeOpeningDbs OpenedVolatileDB
        ChainDB.StartedOpeningLgrDB ->
          traceWith tr $ NodeOpeningDbs StartedOpeningLgrDB
        ChainDB.OpenedLgrDB ->
          traceWith tr $ NodeOpeningDbs OpenedLgrDB
        _ -> return ()
    ChainDB.TraceLedgerDBEvent (LedgerDB.LedgerReplayEvent ev') ->
      case ev' of
        LedgerDB.TraceReplayStartEvent ev'' -> case ev'' of
          LgrDb.ReplayFromGenesis ->
            traceWith tr $ NodeReplays ReplayFromGenesis
          LgrDb.ReplayFromSnapshot _ (LgrDb.ReplayStart rs) ->
              traceWith tr
            $ NodeReplays
            $ ReplayFromSnapshot
            $ withOrigin
                (error "Impossible, replaying from a snapshot at Genesis which should not exist!")
                id
            $ pointSlot rs
        LedgerDB.TraceReplayProgressEvent ev'' -> case ev'' of
          LgrDb.ReplayedBlock (RP.RealPoint s _) _ (LgrDb.ReplayStart rs) (LgrDb.ReplayGoal rp) ->
            traceWith tr $ NodeReplays $ ReplayedBlock s (pointSlot rs) (pointSlot rp)
    ChainDB.TraceInitChainSelEvent ev' ->
      case ev' of
        ChainDB.StartedInitChainSelection ->
          traceWith tr $ NodeInitChainSelection InitChainStartedSelection
        ChainDB.InitialChainSelected ->
          traceWith tr $ NodeInitChainSelection InitChainSelected
        _ -> return ()
    ChainDB.TraceAddBlockEvent ev' ->
      case ev' of
        ChainDB.AddedToCurrentChain _ (ChainDB.SelectionChangedInfo currentTip ntEpoch sInEpoch _ _ _) _ _ -> do
          -- The slot of the latest block consumed (our progress).
          let RP.RealPoint ourSlotSinceSystemStart _ = currentTip
          -- The slot corresponding to the latest wall-clock time (our target).
          slotSinceSystemStart <- getSlotForNow
          let syncProgressPct :: SyncPercentage
              syncProgressPct = (   fromIntegral (unSlotNo ourSlotSinceSystemStart)
                                  / fromIntegral (unSlotNo slotSinceSystemStart)
                                ) * 100.0
          traceWith tr $ NodeAddBlock $
            AddedToCurrentChain ntEpoch (SlotNo sInEpoch) syncProgressPct
        _ -> return ()
    _ -> return ()

traceNodeStateStartup
  :: Trace IO NodeState
  -> Startup.StartupTrace blk
  -> IO ()
traceNodeStateStartup tr ev =
  case ev of
    Startup.StartupSocketConfigError e ->
      traceWith tr $ NodeStartup $ StartupSocketConfigError (textShow e)
    Startup.StartupDBValidation ->
      traceWith tr $ NodeStartup StartupDBValidation
    Startup.NetworkConfigUpdate ->
      traceWith tr $ NodeStartup NetworkConfigUpdate
    Startup.NetworkConfigUpdateError e ->
      traceWith tr $ NodeStartup $ NetworkConfigUpdateError e
    Startup.NonP2PWarning ->
      traceWith tr $ NodeStartup NonP2PWarning
    Startup.WarningDevelopmentNodeToNodeVersions ntnVersions ->
      traceWith tr $ NodeStartup (WarningDevelopmentNodeToNodeVersions ntnVersions)
    Startup.WarningDevelopmentNodeToClientVersions ntcVersions ->
      traceWith tr $ NodeStartup (WarningDevelopmentNodeToClientVersions ntcVersions)
    -- TODO: why other constructors are not traced?
    _ -> return ()

traceNodeStateShutdown
  :: Trace IO NodeState
  -> ShutdownTrace
  -> IO ()
traceNodeStateShutdown tr = traceWith tr . NodeShutdown

-- Misc.

getSlotForNow :: IO SlotNo
getSlotForNow = do
  posixNow <- utc2s <$> getCurrentTime
  -- Since Shelley era the slot length is 1 second, so the number of seconds is the number of slots.
  let numberOfSlotsFromShelleyTillNow = posixNow - posixStartOfShelleyEra
      totalNumberOfSlotsTillNow = numberOfSlotsInByronEra + numberOfSlotsFromShelleyTillNow
  return $ SlotNo totalNumberOfSlotsTillNow
 where
  -- These numbers are taken from 'First-Block-of-Each-Era' wiki page.
  posixStartOfShelleyEra = 1596073491
  numberOfSlotsInByronEra = 4492799
  utc2s = fromInteger . round . utcTimeToPOSIXSeconds
