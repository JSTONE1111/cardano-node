{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}

{-# OPTIONS_GHC -Wno-orphans  #-}
{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}


module Cardano.Tracing.Tracers
  ( Tracers (..)
  , TraceOptions
  , mkTracers
  , nullTracersP2P
  , nullTracersNonP2P
  , traceCounter
  ) where

import           Cardano.BM.Data.Aggregated (Measurable (..))
import           Cardano.BM.Data.Tracer (WithSeverity (..), annotateSeverity)
import           Cardano.BM.Data.Transformers
import           Cardano.BM.Internal.ElidingTracer
import           Cardano.BM.Trace (traceNamedObject)
import           Cardano.BM.Tracing
import           Cardano.Node.Configuration.Logging
import           Cardano.Node.Protocol.Byron ()
import           Cardano.Node.Protocol.Shelley ()
import           Cardano.Node.Queries
import           Cardano.Node.Startup
import qualified Cardano.Node.STM as STM
import           Cardano.Node.TraceConstraints
import           Cardano.Node.Tracing
import           Cardano.Node.Tracing.Tracers.NodeVersion
import           Cardano.Protocol.TPraos.OCert (KESPeriod (..))
import           Cardano.Slotting.Slot (EpochNo (..), SlotNo (..), WithOrigin (..))
import           Cardano.Tracing.Config
import           Cardano.Tracing.HasIssuer (BlockIssuerVerificationKeyHash (..), HasIssuer (..))
import           Cardano.Tracing.Metrics
import           Cardano.Tracing.OrphanInstances.Network ()
import           Cardano.Tracing.Render (renderChainHash, renderHeaderHash)
import           Cardano.Tracing.Shutdown ()
import           Cardano.Tracing.Startup ()
import           Ouroboros.Consensus.Block (BlockConfig, BlockProtocol, CannotForge,
                   ConvertRawHash (..), ForgeStateInfo, ForgeStateUpdateError, Header,
                   realPointHash, realPointSlot)
import           Ouroboros.Consensus.BlockchainTime (SystemStart (..),
                   TraceBlockchainTimeEvent (..))
import           Ouroboros.Consensus.HeaderValidation (OtherHeaderEnvelopeError)
import           Ouroboros.Consensus.Ledger.Abstract (LedgerErr, LedgerState)
import           Ouroboros.Consensus.Ledger.Extended (ledgerState)
import           Ouroboros.Consensus.Ledger.Inspect (InspectLedger, LedgerEvent)
import           Ouroboros.Consensus.Ledger.Query (BlockQuery, Query)
import           Ouroboros.Consensus.Ledger.SupportsMempool (ApplyTxErr, GenTx, GenTxId, HasTxs,
                   LedgerSupportsMempool, ByteSize32 (..))
import           Ouroboros.Consensus.Ledger.SupportsProtocol (LedgerSupportsProtocol)
import           Ouroboros.Consensus.Mempool (MempoolSize (..), TraceEventMempool (..))
import           Ouroboros.Consensus.MiniProtocol.BlockFetch.Server
import           Ouroboros.Consensus.MiniProtocol.ChainSync.Server
import qualified Ouroboros.Consensus.Network.NodeToClient as NodeToClient
import qualified Ouroboros.Consensus.Network.NodeToNode as NodeToNode
import           Ouroboros.Consensus.Node (NetworkP2PMode (..))
import qualified Ouroboros.Consensus.Node.Run as Consensus (RunNode)
import qualified Ouroboros.Consensus.Node.Tracers as Consensus
import           Ouroboros.Consensus.Protocol.Abstract (SelectView, ValidationErr)
import qualified Ouroboros.Consensus.Protocol.Ledger.HotKey as HotKey
import qualified Ouroboros.Consensus.Storage.ChainDB as ChainDB
import qualified Ouroboros.Consensus.Storage.LedgerDB as LedgerDB
import           Ouroboros.Consensus.Util.Enclose

import           Cardano.Network.PeerSelection.PeerTrustable (PeerTrustable)
import qualified Ouroboros.Cardano.Network.PeerSelection.Governor.PeerSelectionState as Cardano
import qualified Ouroboros.Cardano.Network.PeerSelection.Governor.Types as Cardano
import qualified Ouroboros.Cardano.Network.PublicRootPeers as Cardano.PublicRootPeers

import qualified Ouroboros.Network.AnchoredFragment as AF
import           Ouroboros.Network.Block (BlockNo (..), ChainUpdate (..), HasHeader (..), Point,
                   StandardHash, blockNo, pointSlot, unBlockNo)
import           Ouroboros.Network.BlockFetch.ClientState (TraceFetchClientState (..),
                   TraceLabelPeer (..))
import           Ouroboros.Network.BlockFetch.Decision (FetchDecision, FetchDecline (..))
import           Ouroboros.Network.BlockFetch.Decision.Trace
import           Ouroboros.Network.ConnectionId (ConnectionId)
import qualified Ouroboros.Network.ConnectionManager.Core as ConnectionManager
import           Ouroboros.Network.ConnectionManager.Types (ConnectionManagerCounters (..))
import qualified Ouroboros.Network.Diffusion as Diffusion
import qualified Ouroboros.Network.Diffusion.Common as Diffusion
import qualified Ouroboros.Network.Diffusion.NonP2P as NonP2P
import qualified Ouroboros.Network.Diffusion.P2P as P2P
import qualified Ouroboros.Network.Driver.Stateful as Stateful
import qualified Ouroboros.Network.InboundGovernor as InboundGovernor
import           Ouroboros.Network.InboundGovernor.State as InboundGovernor
import           Ouroboros.Network.NodeToClient (LocalAddress)
import           Ouroboros.Network.NodeToNode (RemoteAddress)
import           Ouroboros.Network.PeerSelection.Churn (ChurnCounters (..))
import           Ouroboros.Network.PeerSelection.Governor (
                   PeerSelectionCounters, PeerSelectionView (..))
import qualified Ouroboros.Network.PeerSelection.Governor as Governor
import           Ouroboros.Network.Point (fromWithOrigin)
import           Ouroboros.Network.Protocol.LocalStateQuery.Type (LocalStateQuery, ShowQuery)
import qualified Ouroboros.Network.Protocol.LocalStateQuery.Type as LocalStateQuery
import           Ouroboros.Network.TxSubmission.Inbound

import           Codec.CBOR.Read (DeserialiseFailure)
import           Control.Concurrent (MVar, modifyMVar_)
import           Control.Concurrent.STM (STM, atomically)
import qualified Control.Concurrent.STM as STM
import           Control.Monad (forM_, when)
import           "contra-tracer" Control.Tracer
import           Control.Tracer.Transformers
import           Data.Aeson (ToJSON (..), Value (..))
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Base16 as B16
import           Data.Functor ((<&>))
import           Data.Int (Int64)
import           Data.IntPSQ (IntPSQ)
import qualified Data.IntPSQ as Pq
import qualified Data.Map.Strict as Map
import           Data.Proxy (Proxy (..))
import           Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import           Data.Time (NominalDiffTime, UTCTime)
import           Data.Word (Word64)
import           GHC.Clock (getMonotonicTimeNSec)
import           GHC.TypeLits (KnownNat, Nat, natVal)
import qualified System.Metrics.Counter as Counter
import qualified System.Metrics.Gauge as Gauge
import qualified System.Metrics.Label as Label
import qualified System.Remote.Monitoring.Wai as EKG



{-# OPTIONS_GHC -Wno-redundant-constraints #-}
-- needs different instances on ghc8 and on ghc9

{- HLINT ignore "Redundant bracket" -}
{- HLINT ignore "Use record patterns" -}

data ForgeTracers = ForgeTracers
  { ftForged :: Trace IO Text
  , ftForgeAboutToLead :: Trace IO Text
  , ftCouldNotForge :: Trace IO Text
  , ftAdopted :: Trace IO Text
  , ftDidntAdoptBlock :: Trace IO Text
  , ftForgedInvalid   :: Trace IO Text
  , ftTraceNodeNotLeader  :: Trace IO Text
  , ftTraceNodeCannotForge :: Trace IO Text
  , ftTraceForgeStateUpdateError :: Trace IO Text
  , ftTraceBlockFromFuture :: Trace IO Text
  , ftTraceSlotIsImmutable :: Trace IO Text
  , ftTraceNodeIsLeader :: Trace IO Text
  , ftTraceAdoptionThreadDied :: Trace IO Text
  }

nullTracersP2P :: Applicative m => Tracers peer localPeer blk 'Diffusion.P2P extraState extraDebugState extraFlags extraPeers extraCounters m
nullTracersP2P = Tracers
  { chainDBTracer = nullTracer
  , consensusTracers = Consensus.nullTracers
  , nodeToClientTracers = NodeToClient.nullTracers
  , nodeToNodeTracers = NodeToNode.nullTracers
  , diffusionTracers = Diffusion.nullTracers
  , diffusionTracersExtra = Diffusion.P2PTracers P2P.nullTracersExtra
  , startupTracer = nullTracer
  , shutdownTracer = nullTracer
  , nodeInfoTracer = nullTracer
  , nodeStartupInfoTracer = nullTracer
  , nodeStateTracer = nullTracer
  , nodeVersionTracer = nullTracer
  , resourcesTracer = nullTracer
  , peersTracer = nullTracer
  , ledgerMetricsTracer = nullTracer
  }

nullTracersNonP2P :: Tracers peer localPeer blk 'Diffusion.NonP2P extraState extraDebugState extraFlags extraPeers extraCounters m
nullTracersNonP2P = Tracers
  { chainDBTracer = nullTracer
  , consensusTracers = Consensus.nullTracers
  , nodeToClientTracers = NodeToClient.nullTracers
  , nodeToNodeTracers = NodeToNode.nullTracers
  , diffusionTracers = Diffusion.nullTracers
  , diffusionTracersExtra = Diffusion.NonP2PTracers NonP2P.nullTracers
  , startupTracer = nullTracer
  , shutdownTracer = nullTracer
  , nodeInfoTracer = nullTracer
  , nodeStartupInfoTracer = nullTracer
  , nodeStateTracer = nullTracer
  , nodeVersionTracer = nullTracer
  , resourcesTracer = nullTracer
  , peersTracer = nullTracer
  , ledgerMetricsTracer = nullTracer
  }

indexGCType :: ChainDB.TraceGCEvent a -> Int
indexGCType ChainDB.ScheduledGC{} = 1
indexGCType ChainDB.PerformedGC{} = 2

instance ElidingTracer (WithSeverity (ChainDB.TraceEvent blk)) where
  -- equivalent by type and severity
  isEquivalent (WithSeverity s1 (ChainDB.TraceGCEvent ev1))
               (WithSeverity s2 (ChainDB.TraceGCEvent ev2)) =
                  s1 == s2 && indexGCType ev1 == indexGCType ev2
  isEquivalent (WithSeverity _s1 (ChainDB.TraceAddBlockEvent _))
               (WithSeverity _s2 (ChainDB.TraceAddBlockEvent _)) = True
  isEquivalent (WithSeverity _s1 (ChainDB.TraceGCEvent _ev1))
               (WithSeverity _s2 (ChainDB.TraceAddBlockEvent _)) = True
  isEquivalent (WithSeverity _s1 (ChainDB.TraceAddBlockEvent _))
               (WithSeverity _s2 (ChainDB.TraceGCEvent _ev2)) = True
  isEquivalent (WithSeverity _s1 (ChainDB.TraceGCEvent _ev1))
               (WithSeverity _s2 (ChainDB.TraceCopyToImmutableDBEvent _)) = True
  isEquivalent (WithSeverity _s1 (ChainDB.TraceCopyToImmutableDBEvent _))
               (WithSeverity _s2 (ChainDB.TraceGCEvent _ev2)) = True
  isEquivalent (WithSeverity _s1 (ChainDB.TraceCopyToImmutableDBEvent _))
               (WithSeverity _s2 (ChainDB.TraceAddBlockEvent _)) = True
  isEquivalent (WithSeverity _s1 (ChainDB.TraceAddBlockEvent _))
               (WithSeverity _s2 (ChainDB.TraceCopyToImmutableDBEvent _)) = True
  isEquivalent (WithSeverity _s1 (ChainDB.TraceCopyToImmutableDBEvent _))
               (WithSeverity _s2 (ChainDB.TraceCopyToImmutableDBEvent _)) = True
  isEquivalent (WithSeverity _s1 (ChainDB.TraceLedgerDBEvent
                                  (LedgerDB.LedgerReplayEvent
                                   (LedgerDB.TraceReplayProgressEvent _))))
               (WithSeverity _s2 (ChainDB.TraceLedgerDBEvent
                                  (LedgerDB.LedgerReplayEvent
                                   (LedgerDB.TraceReplayProgressEvent _)))) = True
  -- HACK: we never want any of the forker or flavor events to break the elision.
  --
  -- when a forker event arrives, it will be compared as @(ev `isEquivalent`)@, but once it is
  -- processed the next time it will be compared as @(`isEquivalent` ev)@, hence the flipped
  -- versions below this comment
  isEquivalent (WithSeverity _s1 (ChainDB.TraceLedgerDBEvent LedgerDB.LedgerDBForkerEvent{})) _ = True
  isEquivalent (WithSeverity _s1 (ChainDB.TraceLedgerDBEvent LedgerDB.LedgerDBFlavorImplEvent{})) _ = True
  isEquivalent _ (WithSeverity _s1 (ChainDB.TraceLedgerDBEvent LedgerDB.LedgerDBForkerEvent{})) = True
  isEquivalent _ (WithSeverity _s1 (ChainDB.TraceLedgerDBEvent LedgerDB.LedgerDBFlavorImplEvent{})) = True
  isEquivalent (WithSeverity _s1 (ChainDB.TraceInitChainSelEvent ev1))
               (WithSeverity _s2 (ChainDB.TraceInitChainSelEvent ev2)) =
    case (ev1, ev2) of
      (ChainDB.InitChainSelValidation (
        ChainDB.UpdateLedgerDbTraceEvent (
            LedgerDB.StartedPushingBlockToTheLedgerDb _ _ _)),
       ChainDB.InitChainSelValidation (
        ChainDB.UpdateLedgerDbTraceEvent (
            LedgerDB.StartedPushingBlockToTheLedgerDb _ _ _))) -> True
      _ -> False
  isEquivalent _ _ = False
  -- the types to be elided
  doelide (WithSeverity _ (ChainDB.TraceLedgerDBEvent
                                  (LedgerDB.LedgerReplayEvent
                                   (LedgerDB.TraceReplayProgressEvent _)))) = True
  doelide (WithSeverity _ (ChainDB.TraceLedgerDBEvent
                                  LedgerDB.LedgerDBForkerEvent{})) = True
  doelide (WithSeverity _ (ChainDB.TraceLedgerDBEvent
                                  LedgerDB.LedgerDBFlavorImplEvent{})) = True
  doelide (WithSeverity _ (ChainDB.TraceGCEvent _)) = True
  doelide (WithSeverity _ (ChainDB.TraceAddBlockEvent (ChainDB.IgnoreBlockOlderThanK _))) = False
  doelide (WithSeverity _ (ChainDB.TraceAddBlockEvent (ChainDB.IgnoreInvalidBlock _ _))) = False
  doelide (WithSeverity _ (ChainDB.TraceAddBlockEvent (ChainDB.StoreButDontChange _))) = False
  doelide (WithSeverity _ (ChainDB.TraceAddBlockEvent (ChainDB.TrySwitchToAFork _ _))) = False
  doelide (WithSeverity _ (ChainDB.TraceAddBlockEvent (ChainDB.SwitchedToAFork{}))) = False
  doelide (WithSeverity _ (ChainDB.TraceAddBlockEvent (ChainDB.AddBlockValidation (ChainDB.InvalidBlock _ _)))) = False
  doelide (WithSeverity _ (ChainDB.TraceAddBlockEvent (ChainDB.AddBlockValidation _))) = True
  doelide (WithSeverity _ (ChainDB.TraceAddBlockEvent (ChainDB.AddedToCurrentChain events _ _ _))) = null events
  doelide (WithSeverity _ (ChainDB.TraceAddBlockEvent (ChainDB.PipeliningEvent{}))) = True
  doelide (WithSeverity _ (ChainDB.TraceAddBlockEvent _)) = True
  doelide (WithSeverity _ (ChainDB.TraceCopyToImmutableDBEvent _)) = True
  doelide (WithSeverity _ (ChainDB.TraceInitChainSelEvent (ChainDB.InitChainSelValidation (ChainDB.UpdateLedgerDbTraceEvent{})))) = True
  doelide _ = False

  conteliding _tverb _tr _ (Nothing, _count) = return (Nothing, 0)
  conteliding tverb tr ev@(WithSeverity _ (ChainDB.TraceAddBlockEvent ChainDB.AddedToCurrentChain{})) (_old, oldt) = do
      tnow <- getMonotonicTimeNSec
      let tnow' = fromIntegral tnow
          deltat = tnow' - oldt
      if deltat > 1250000000 -- report at most every 1250 ms
        then do
          traceWith (toLogObject' tverb tr) ev
          return (Just ev, tnow')
        else return (Just ev, oldt)
  conteliding _tverb _tr ev@(WithSeverity _ (ChainDB.TraceAddBlockEvent _)) (_old, count) =
      return (Just ev, count)
  conteliding _tverb _tr ev@(WithSeverity _ (ChainDB.TraceCopyToImmutableDBEvent _)) (_old, count) =
      return (Just ev, count)
  conteliding _tverb _tr ev@(WithSeverity _ (ChainDB.TraceGCEvent _)) (_old, count) =
      return (Just ev, count)
  conteliding _tverb _tr ev@(WithSeverity _ (ChainDB.TraceLedgerDBEvent
                                  (LedgerDB.LedgerReplayEvent
                                   (LedgerDB.TraceReplayProgressEvent _)))) (_old, count) = do
      return (Just ev, count)
  conteliding _tverb _tr ev@(WithSeverity _ (ChainDB.TraceLedgerDBEvent LedgerDB.LedgerDBForkerEvent{})) (_old, count) = do
      return (Just ev, count)
  conteliding _tverb _tr ev@(WithSeverity _ (ChainDB.TraceLedgerDBEvent LedgerDB.LedgerDBFlavorImplEvent{})) (_old, count) = do
      return (Just ev, count)
  conteliding _tverb _tr ev@(WithSeverity _ (ChainDB.TraceInitChainSelEvent
                                             (ChainDB.InitChainSelValidation
                                              (ChainDB.UpdateLedgerDbTraceEvent
                                               (LedgerDB.StartedPushingBlockToTheLedgerDb
                                                _ _ (LedgerDB.Pushing curr)))))) (_old, count) = return $
    let currSlot = fromIntegral $ unSlotNo $ realPointSlot curr in
      if count == 0
      then (Just ev, currSlot)
      else if count + 10000 < currSlot
           then (Nothing, 0)
           else (Just ev, count)
  conteliding _ _ _ _ = return (Nothing, 0)

  reportelided _tverb _tr (WithSeverity _ (ChainDB.TraceLedgerDBEvent
                                  (LedgerDB.LedgerReplayEvent
                                   (LedgerDB.TraceReplayProgressEvent _)))) _count = pure ()
  reportelided t tr ev count = defaultelidedreporting  t tr ev count

instance (StandardHash header, Eq peer) => ElidingTracer
  (WithSeverity [TraceLabelPeer peer (FetchDecision [Point header])]) where
  -- equivalent by type and severity
  isEquivalent (WithSeverity s1 _peers1)
               (WithSeverity s2 _peers2) = s1 == s2
  -- the types to be elided
  doelide (WithSeverity _ peers) =
    let checkDecision :: TraceLabelPeer peer (Either FetchDecline result) -> Bool
        checkDecision (TraceLabelPeer _peer (Left FetchDeclineChainNotPlausible)) = True
        checkDecision (TraceLabelPeer _peer (Left (FetchDeclineConcurrencyLimit _ _))) = True
        checkDecision (TraceLabelPeer _peer (Left (FetchDeclinePeerBusy _ _ _))) = True
        checkDecision _ = False
    in any checkDecision peers
  conteliding _tverb _tr _ (Nothing, _count) = return (Nothing, 0)
  conteliding tverb tr ev (_old, count) = do
      when (count > 0 && count `mod` 1000 == 0) $  -- report every 1000th message
          traceWith (toLogObject' tverb tr) ev
      return (Just ev, count + 1)

-- | Tracers for all system components.
--
mkTracers
  :: forall blk p2p .
     ( Consensus.RunNode blk
     , TraceConstraints blk
     )
  => BlockConfig blk
  -> TraceOptions
  -> Trace IO Text
  -> NodeKernelData blk
  -> Maybe EKGDirect
  -> NetworkP2PMode p2p
  -> IO (Tracers RemoteAddress
                 LocalAddress
                 blk p2p
                 Cardano.ExtraState
                 Cardano.DebugPeerSelectionState
                 PeerTrustable
                 (Cardano.PublicRootPeers.ExtraPeers RemoteAddress)
                 (Cardano.ExtraPeerSelectionSetsWithSizes RemoteAddress)
                 IO)
mkTracers blockConfig tOpts@(TracingOnLegacy trSel) tr nodeKern ekgDirect enableP2P = do
  fStats <- mkForgingStats
  consensusTracers <- mkConsensusTracers ekgDirect trSel verb tr nodeKern fStats
  elidedChainDB <- newstate  -- for eliding messages in ChainDB tracer
  tForks <- STM.newTVarIO 0

  pure Tracers
    { chainDBTracer = tracerOnOff' (traceChainDB trSel) $
        annotateSeverity $ teeTraceChainTip
                             blockConfig
                             fStats
                             tOpts elidedChainDB
                             ekgDirect
                             tForks
                             (appendName "ChainDB" tr)
                             (appendName "metrics" tr)
    , consensusTracers = consensusTracers
    , nodeToClientTracers = nodeToClientTracers' trSel verb tr
    , nodeToNodeTracers = nodeToNodeTracers' trSel verb tr
    , diffusionTracers
    , diffusionTracersExtra = diffusionTracersExtra' enableP2P
    -- TODO: startupTracer should ignore severity level (i.e. it should always
    -- be printed)!
    , startupTracer = toLogObject' verb (appendName "startup" tr)
              <> Tracer (\(ev :: StartupTrace blk) -> traceForgeEnabledMetric ekgDirect ev)

    , shutdownTracer = toLogObject' verb $ appendName "shutdown" tr
    , nodeVersionTracer = Tracer (\(ev :: NodeVersionTrace) -> traceVersionMetric ekgDirect ev)
    -- The remaining tracers are completely unused by the legacy tracing:
    , nodeInfoTracer = nullTracer
    , nodeStartupInfoTracer = nullTracer
    , nodeStateTracer = nullTracer
    , resourcesTracer = nullTracer
    , peersTracer = nullTracer
    , ledgerMetricsTracer = nullTracer
    }
 where
   traceForgeEnabledMetric :: Maybe EKGDirect -> StartupTrace blk -> IO ()
   traceForgeEnabledMetric mbEKGDirect ev =
      case mbEKGDirect of
        Just ekgDirect' ->
          case ev of
              BlockForgingUpdate b -> sendEKGDirectInt ekgDirect' "cardano.node.metrics.forging_enabled"
                                        (case b of
                                            EnabledBlockForging -> 1 :: Int
                                            DisabledBlockForging -> 0 :: Int
                                            NotEffective -> 0 :: Int)
              _ -> pure ()
        Nothing -> pure ()
   traceVersionMetric :: Maybe EKGDirect -> NodeVersionTrace -> IO ()
   traceVersionMetric mbEKGDirect ev = do
      case mbEKGDirect of
        Just ekgDirect' ->
          case ev of
              NodeVersionTrace {} ->
                  sendEKGDirectPrometheusLabel
                    ekgDirect'
                    "cardano.node.metrics.cardano_build_info"
                    (getCardanoBuildInfo ev)
        Nothing -> pure ()

   diffusionTracers = Diffusion.Tracers
     { Diffusion.dtMuxTracer            = muxTracer
     , Diffusion.dtHandshakeTracer      = handshakeTracer
     , Diffusion.dtLocalMuxTracer       = localMuxTracer
     , Diffusion.dtLocalHandshakeTracer = localHandshakeTracer
     , Diffusion.dtDiffusionTracer      = initializationTracer
     }
   diffusionTracersExtra' enP2P =
     case enP2P of
       EnabledP2PMode ->
         Diffusion.P2PTracers P2P.TracersExtra
           { P2P.dtTraceLocalRootPeersTracer =
               tracerOnOff (traceLocalRootPeers trSel)
                            verb "LocalRootPeers" tr
           , P2P.dtTracePublicRootPeersTracer =
               tracerOnOff (tracePublicRootPeers trSel)
                            verb "PublicRootPeers" tr
           , P2P.dtTracePeerSelectionTracer =
                  tracerOnOff (tracePeerSelection trSel)
                               verb "PeerSelection" tr
               <> tracePeerSelectionTracerMetrics
                    (tracePeerSelection trSel)
                    ekgDirect
           , P2P.dtTraceChurnCounters =
               traceChurnCountersMetrics
                 ekgDirect
           , P2P.dtDebugPeerSelectionInitiatorTracer =
               tracerOnOff (traceDebugPeerSelectionInitiatorTracer trSel)
                            verb "DebugPeerSelection" tr
           , P2P.dtDebugPeerSelectionInitiatorResponderTracer =
             tracerOnOff (traceDebugPeerSelectionInitiatorResponderTracer trSel)
                          verb "DebugPeerSelection" tr
           , P2P.dtTracePeerSelectionCounters =
                 tracePeerSelectionCountersMetrics
                   (tracePeerSelectionCounters trSel)
                   ekgDirect
              <> tracerOnOff (tracePeerSelectionCounters trSel)
                             verb "PeerSelectionCounters" tr
           , P2P.dtPeerSelectionActionsTracer =
               tracerOnOff (tracePeerSelectionActions trSel)
                            verb "PeerSelectionActions" tr
           , P2P.dtConnectionManagerTracer =
                 traceConnectionManagerTraceMetrics
                    (traceConnectionManagerCounters trSel)
                    ekgDirect
              <> tracerOnOff (traceConnectionManager trSel)
                              verb "ConnectionManager" tr
           , P2P.dtConnectionManagerTransitionTracer =
               tracerOnOff (traceConnectionManagerTransitions trSel)
                           verb "ConnectionManagerTransition" tr
           , P2P.dtServerTracer =
               tracerOnOff (traceServer trSel) verb "Server" tr
           , P2P.dtInboundGovernorTracer =
                 traceInboundGovernorCountersMetrics
                   (traceInboundGovernorCounters trSel)
                   ekgDirect
              <> tracerOnOff (traceInboundGovernor trSel)
                              verb "InboundGovernor" tr
           , P2P.dtInboundGovernorTransitionTracer =
               tracerOnOff (traceInboundGovernorTransitions trSel)
                           verb "InboundGovernorTransition" tr
           , P2P.dtLocalConnectionManagerTracer =
               tracerOnOff (traceLocalConnectionManager trSel)
                            verb "LocalConnectionManager" tr
           , P2P.dtLocalServerTracer =
               tracerOnOff (traceLocalServer trSel)
                            verb "LocalServer" tr
           , P2P.dtLocalInboundGovernorTracer =
               tracerOnOff (traceLocalInboundGovernor trSel)
                            verb "LocalInboundGovernor" tr
           , P2P.dtTraceLedgerPeersTracer =
               tracerOnOff (traceLedgerPeers trSel)
                            verb "LedgerPeers" tr
           }
       DisabledP2PMode ->
         Diffusion.NonP2PTracers NonP2P.TracersExtra
           { NonP2P.dtIpSubscriptionTracer =
               tracerOnOff (traceIpSubscription trSel) verb "IpSubscription" tr
           , NonP2P.dtDnsSubscriptionTracer =
               tracerOnOff (traceDnsSubscription trSel) verb "DnsSubscription" tr
           , NonP2P.dtDnsResolverTracer =
               tracerOnOff (traceDnsResolver trSel) verb "DnsResolver" tr
           , NonP2P.dtErrorPolicyTracer =
               tracerOnOff (traceErrorPolicy trSel) verb "ErrorPolicy" tr
           , NonP2P.dtLocalErrorPolicyTracer =
               tracerOnOff (traceLocalErrorPolicy trSel) verb "LocalErrorPolicy" tr
           , NonP2P.dtAcceptPolicyTracer =
               tracerOnOff (traceAcceptPolicy trSel) verb "AcceptPolicy" tr
           }
   verb :: TracingVerbosity
   verb = traceVerbosity trSel
   muxTracer =
     tracerOnOff (traceMux trSel) verb "Mux" tr
   localMuxTracer =
     tracerOnOff (traceLocalMux trSel) verb "MuxLocal" tr
   localHandshakeTracer =
     tracerOnOff (traceLocalHandshake trSel) verb "LocalHandshake" tr
   handshakeTracer =
     tracerOnOff (traceHandshake trSel) verb "Handshake" tr
   initializationTracer =
     tracerOnOff (traceDiffusionInitialization trSel) verb
       "DiffusionInitializationTracer" tr

mkTracers _ _ _ _ _ enableP2P =
  pure Tracers
    { chainDBTracer = nullTracer
    , consensusTracers = Consensus.Tracers
      { Consensus.chainSyncClientTracer = nullTracer
      , Consensus.chainSyncServerHeaderTracer = nullTracer
      , Consensus.chainSyncServerBlockTracer = nullTracer
      , Consensus.consensusSanityCheckTracer = nullTracer
      , Consensus.blockFetchDecisionTracer = nullTracer
      , Consensus.blockFetchClientTracer = nullTracer
      , Consensus.blockFetchServerTracer = nullTracer
      , Consensus.keepAliveClientTracer = nullTracer
      , Consensus.forgeStateInfoTracer = nullTracer
      , Consensus.gddTracer = nullTracer
      , Consensus.txInboundTracer = nullTracer
      , Consensus.txOutboundTracer = nullTracer
      , Consensus.localTxSubmissionServerTracer = nullTracer
      , Consensus.mempoolTracer = nullTracer
      , Consensus.forgeTracer = nullTracer
      , Consensus.blockchainTimeTracer = nullTracer
      , Consensus.consensusErrorTracer = nullTracer
      , Consensus.gsmTracer = nullTracer
      , Consensus.csjTracer = nullTracer
      , Consensus.dbfTracer = nullTracer
      }
    , nodeToClientTracers = NodeToClient.Tracers
      { NodeToClient.tChainSyncTracer = nullTracer
      , NodeToClient.tTxMonitorTracer = nullTracer
      , NodeToClient.tTxSubmissionTracer = nullTracer
      , NodeToClient.tStateQueryTracer = nullTracer
      }
    , nodeToNodeTracers = NodeToNode.Tracers
      { NodeToNode.tChainSyncTracer = nullTracer
      , NodeToNode.tChainSyncSerialisedTracer = nullTracer
      , NodeToNode.tBlockFetchTracer = nullTracer
      , NodeToNode.tBlockFetchSerialisedTracer = nullTracer
      , NodeToNode.tTxSubmission2Tracer = nullTracer
      , NodeToNode.tKeepAliveTracer = nullTracer
      , NodeToNode.tPeerSharingTracer = nullTracer
      }
    , diffusionTracers = Diffusion.nullTracers
    , diffusionTracersExtra =
        case enableP2P of
          EnabledP2PMode  -> Diffusion.P2PTracers P2P.nullTracersExtra
          DisabledP2PMode -> Diffusion.NonP2PTracers NonP2P.nullTracers
    , startupTracer = nullTracer
    , shutdownTracer = nullTracer
    , nodeInfoTracer = nullTracer
    , nodeStartupInfoTracer = nullTracer
    , nodeStateTracer = nullTracer
    , nodeVersionTracer = nullTracer
    , resourcesTracer = nullTracer
    , peersTracer = nullTracer
    , ledgerMetricsTracer = nullTracer
    }

--------------------------------------------------------------------------------
-- Chain DB Tracers
--------------------------------------------------------------------------------

teeTraceChainTip
  :: ( ConvertRawHash blk
     , HasIssuer blk
     , LedgerSupportsProtocol blk
     , InspectLedger blk
     , ToObject (Header blk)
     , ToObject (LedgerEvent blk)
     , ToObject (SelectView (BlockProtocol blk))
     )
  => BlockConfig blk
  -> ForgingStats
  -> TraceOptions
  -> MVar (Maybe (WithSeverity (ChainDB.TraceEvent blk)), Integer)
  -> Maybe EKGDirect
  -> STM.TVar Word64
  -> Trace IO Text
  -> Trace IO Text
  -> Tracer IO (WithSeverity (ChainDB.TraceEvent blk))
teeTraceChainTip _ _ TracingOff _ _ _ _ _ = nullTracer
teeTraceChainTip _ _ TraceDispatcher{} _ _ _ _ _ = nullTracer
teeTraceChainTip blockConfig fStats (TracingOnLegacy trSel) elided ekgDirect tFork trTrc trMet =
  Tracer $ \ev -> do
    traceWith (teeTraceChainTipElide (traceVerbosity trSel) elided trTrc) ev
    traceWith (ignoringSeverity (traceChainMetrics ekgDirect tFork blockConfig fStats trMet)) ev

teeTraceChainTipElide
  :: ( ConvertRawHash blk
     , LedgerSupportsProtocol blk
     , InspectLedger blk
     , ToObject (Header blk)
     , ToObject (LedgerEvent blk)
     , ToObject (SelectView (BlockProtocol blk))
     )
  => TracingVerbosity
  -> MVar (Maybe (WithSeverity (ChainDB.TraceEvent blk)), Integer)
  -> Trace IO Text
  -> Tracer IO (WithSeverity (ChainDB.TraceEvent blk))
teeTraceChainTipElide = elideToLogObject
{-# INLINE teeTraceChainTipElide #-}

ignoringSeverity :: Tracer IO a -> Tracer IO (WithSeverity a)
ignoringSeverity tr = Tracer $ \(WithSeverity _ ev) -> traceWith tr ev
{-# INLINE ignoringSeverity #-}

traceChainMetrics
  :: forall blk. ()
  => HasHeader (Header blk)
  => ConvertRawHash blk
  => HasIssuer blk
  => Maybe EKGDirect
  -> STM.TVar Word64
  -> BlockConfig blk
  -> ForgingStats
  -> Trace IO Text
  -> Tracer IO (ChainDB.TraceEvent blk)
traceChainMetrics Nothing _ _ _ _ = nullTracer
traceChainMetrics (Just _ekgDirect) tForks _blockConfig _fStats tr = do
  Tracer $ \ev ->
    maybe (pure ()) doTrace (chainTipInformation ev)
  where
    chainTipInformation :: ChainDB.TraceEvent blk -> Maybe ChainInformation
    chainTipInformation = \case
      ChainDB.TraceAddBlockEvent ev -> case ev of
        ChainDB.SwitchedToAFork _warnings selChangedInfo oldChain newChain ->
          let fork = not $ AF.withinFragmentBounds (AF.headPoint oldChain)
                              newChain in
          Just $ chainInformation selChangedInfo fork oldChain newChain 0
        ChainDB.AddedToCurrentChain _warnings selChangedInfo oldChain newChain ->
          Just $ chainInformation selChangedInfo False oldChain newChain 0
        _ -> Nothing
      _ -> Nothing

    doTrace :: ChainInformation -> IO ()
    doTrace
        ChainInformation { slots, blocks, density, epoch, slotInEpoch, fork, tipBlockHash, tipBlockParentHash, tipBlockIssuerVerificationKeyHash } = do
      -- TODO this is executed each time the newChain changes. How cheap is it?
      meta <- mkLOMeta Critical Public

      traceD tr meta "density"     (fromRational density)
      traceI tr meta "slotNum"     slots
      traceI tr meta "blockNum"    blocks
      traceI tr meta "slotInEpoch" slotInEpoch
      traceI tr meta "epoch"       (unEpochNo epoch)
      when fork $
        traceI tr meta "forks" =<< STM.modifyReadTVarIO tForks succ

      let tipBlockIssuerVkHashText :: Text
          tipBlockIssuerVkHashText =
            case tipBlockIssuerVerificationKeyHash of
              NoBlockIssuer -> "NoBlockIssuer"
              BlockIssuerVerificationKeyHash bs ->
                Text.decodeLatin1 (B16.encode bs)
      traceNamedObject
        (appendName "tipBlockHash" tr)
        (meta, LogMessage tipBlockHash)

      traceNamedObject
        (appendName "tipBlockParentHash" tr)
        (meta, LogMessage tipBlockParentHash)

      traceNamedObject
        (appendName "tipBlockIssuerVerificationKeyHash" tr)
        (meta, LogMessage tipBlockIssuerVkHashText)

traceD :: Trace IO a -> LOMeta -> Text -> Double -> IO ()
traceD tr meta msg d = traceNamedObject tr (meta, LogValue msg (PureD d))

traceI :: Integral i => Trace IO a -> LOMeta -> Text -> i -> IO ()
traceI tr meta msg i = traceNamedObject tr (meta, LogValue msg (PureI (fromIntegral i)))

sendEKGDirectCounter :: EKGDirect -> Text -> IO ()
sendEKGDirectCounter ekgDirect name = do
  modifyMVar_ (ekgCounters ekgDirect) $ \registeredMap -> do
    case Map.lookup name registeredMap of
      Just counter -> do
        Counter.inc counter
        pure registeredMap
      Nothing -> do
        counter <- EKG.getCounter name (ekgServer ekgDirect)
        Counter.inc counter
        pure $ Map.insert name counter registeredMap

sendEKGDirectInt :: Integral a => EKGDirect -> Text -> a -> IO ()
sendEKGDirectInt ekgDirect name val = do
  modifyMVar_ (ekgGauges ekgDirect) $ \registeredMap -> do
    case Map.lookup name registeredMap of
      Just gauge -> do
        Gauge.set gauge (fromIntegral val)
        pure registeredMap
      Nothing -> do
        gauge <- EKG.getGauge name (ekgServer ekgDirect)
        Gauge.set gauge (fromIntegral val)
        pure $ Map.insert name gauge registeredMap

sendEKGDirectDouble :: EKGDirect -> Text -> Double -> IO ()
sendEKGDirectDouble ekgDirect name val = do
  modifyMVar_ (ekgLabels ekgDirect) $ \registeredMap -> do
    case Map.lookup name registeredMap of
      Just label -> do
        Label.set label (Text.pack (show val))
        pure registeredMap
      Nothing -> do
        label <- EKG.getLabel name (ekgServer ekgDirect)
        Label.set label (Text.pack (show val))
        pure $ Map.insert name label registeredMap

sendEKGDirectPrometheusLabel :: EKGDirect -> Text -> [(Text,Text)] -> IO ()
sendEKGDirectPrometheusLabel ekgDirect name labels = do
  modifyMVar_ (ekgLabels ekgDirect) $ \registeredMap -> do
    case Map.lookup name registeredMap of
      Just label -> do
        Label.set label (presentPrometheusM labels)
        pure registeredMap
      Nothing -> do
        label <- EKG.getLabel name (ekgServer ekgDirect)
        Label.set label (presentPrometheusM labels)
        pure $ Map.insert name label registeredMap
  where
    presentPrometheusM :: [(Text, Text)] -> Text
    presentPrometheusM =
      label . map pair
      where
        label pairs = "{" <> Text.intercalate "," pairs <> "}"
        pair (k, v) = k <> "=\"" <> v <> "\""

--------------------------------------------------------------------------------
-- Consensus Tracers
--------------------------------------------------------------------------------

isRollForward :: TraceChainSyncServerEvent blk -> Bool
isRollForward (TraceChainSyncServerUpdate _tip (AddBlock _pt) _blocking FallingEdge) = True
isRollForward _ = False

mkConsensusTracers
  :: forall blk peer localPeer.
     ( Show peer
     , Eq peer
     , ToObject peer
     , ToJSON peer
     , LedgerQueries blk
     , ToJSON (GenTxId blk)
     , ToObject (ApplyTxErr blk)
     , ToObject (CannotForge blk)
     , ToObject (GenTx blk)
     , ToObject (LedgerErr (LedgerState blk))
     , ToObject (OtherHeaderEnvelopeError blk)
     , ToObject (ValidationErr (BlockProtocol blk))
     , ToObject (ForgeStateUpdateError blk)
     , Consensus.RunNode blk
     , HasKESMetricsData blk
     , HasKESInfo blk
     )
  => Maybe EKGDirect
  -> TraceSelection
  -> TracingVerbosity
  -> Trace IO Text
  -> NodeKernelData blk
  -> ForgingStats
  -> IO (Consensus.Tracers' peer localPeer blk (Tracer IO))
mkConsensusTracers mbEKGDirect trSel verb tr nodeKern fStats = do
  let trmet = appendName "metrics" tr

  elidedFetchDecision <- newstate  -- for eliding messages in FetchDecision tr
  forgeTracers <- mkForgeTracers
  meta <- mkLOMeta Critical Public

  tBlocksServed <- STM.newTVarIO 0
  tLocalUp <- STM.newTVarIO 0
  tMaxSlotNo <- STM.newTVarIO $ SlotNo 0
  tSubmissionsCollected <- STM.newTVarIO 0
  tSubmissionsAccepted <- STM.newTVarIO 0
  tSubmissionsRejected <- STM.newTVarIO 0
  tBlockDelayM <- STM.newTVarIO Pq.empty
  tBlockDelayCDF1s <- STM.newTVarIO $ CdfCounter 0
  tBlockDelayCDF3s <- STM.newTVarIO $ CdfCounter 0
  tBlockDelayCDF5s <- STM.newTVarIO $ CdfCounter 0
  pure Consensus.Tracers
    { Consensus.chainSyncClientTracer = tracerOnOff (traceChainSyncClient trSel) verb "ChainSyncClient" tr
    , Consensus.chainSyncServerHeaderTracer =
           tracerOnOff' (traceChainSyncHeaderServer trSel)
                        (annotateSeverity . toLogObject' verb $ appendName "ChainSyncHeaderServer" tr)
        <> (\(TraceLabelPeer _ ev) -> ev) `contramap` Tracer (traceServedCount mbEKGDirect)
    , Consensus.chainSyncServerBlockTracer = tracerOnOff (traceChainSyncBlockServer trSel) verb "ChainSyncBlockServer" tr
    , Consensus.consensusSanityCheckTracer = tracerOnOff (traceSanityCheckIssue trSel) verb "ConsensusSanityCheck" tr
    , Consensus.blockFetchDecisionTracer = tracerOnOff' (traceBlockFetchDecisions trSel) $
        annotateSeverity $ teeTraceBlockFetchDecision verb elidedFetchDecision tr
    , Consensus.blockFetchClientTracer = traceBlockFetchClientMetrics mbEKGDirect tBlockDelayM
        tBlockDelayCDF1s tBlockDelayCDF3s tBlockDelayCDF5s $
            tracerOnOff (traceBlockFetchClient trSel) verb "BlockFetchClient" tr
    , Consensus.blockFetchServerTracer = traceBlockFetchServerMetrics trmet meta tBlocksServed
        tLocalUp tMaxSlotNo $ tracerOnOff (traceBlockFetchServer trSel) verb "BlockFetchServer" tr
    , Consensus.gddTracer = tracerOnOff (traceGDD trSel) verb "GDD" tr
    , Consensus.keepAliveClientTracer = tracerOnOff (traceKeepAliveClient trSel) verb "KeepAliveClient" tr
    , Consensus.forgeStateInfoTracer = tracerOnOff' (traceForgeStateInfo trSel) $
        forgeStateInfoTracer (Proxy @blk) trSel tr
    , Consensus.txInboundTracer = tracerOnOff' (traceTxInbound trSel) $
          Tracer $ \ev -> do
            traceWith (annotateSeverity . toLogObject' verb $ appendName "TxInbound" tr) ev
            case ev of
              TraceLabelPeer _ (TraceTxSubmissionCollected collected) ->
                traceI trmet meta "submissions.submitted.count" =<<
                  STM.modifyReadTVarIO tSubmissionsCollected (+ collected)

              TraceLabelPeer _ (TraceTxSubmissionProcessed processed) -> do
                traceI trmet meta "submissions.accepted.count" =<<
                  STM.modifyReadTVarIO tSubmissionsAccepted (+ ptxcAccepted processed)
                traceI trmet meta "submissions.rejected.count" =<<
                  STM.modifyReadTVarIO tSubmissionsRejected (+ ptxcRejected processed)

              TraceLabelPeer _ TraceTxInboundTerminated -> return ()
              TraceLabelPeer _ (TraceTxInboundCanRequestMoreTxs _) -> return ()
              TraceLabelPeer _ (TraceTxInboundCannotRequestMoreTxs _) -> return ()

    , Consensus.txOutboundTracer = tracerOnOff (traceTxOutbound trSel) verb "TxOutbound" tr
    , Consensus.localTxSubmissionServerTracer = tracerOnOff (traceLocalTxSubmissionServer trSel) verb "LocalTxSubmissionServer" tr
    , Consensus.mempoolTracer = tracerOnOff' (traceMempool trSel) $ mempoolTracer trSel tr fStats
    , Consensus.forgeTracer = tracerOnOff' (traceForge trSel) $
        Tracer $ \tlcev@Consensus.TraceLabelCreds{} -> do
          traceWith (annotateSeverity
                     $ traceLeadershipChecks forgeTracers nodeKern verb tr) tlcev
          traceWith (forgeTracer verb tr forgeTracers fStats) tlcev

    , Consensus.blockchainTimeTracer = tracerOnOff' (traceBlockchainTime trSel) $
        Tracer $ \ev ->
          traceWith (toLogObject tr) (readableTraceBlockchainTimeEvent ev)
    , Consensus.consensusErrorTracer =
        Tracer $ \err -> traceWith (toLogObject tr) (ConsensusStartupException err)
    , Consensus.gsmTracer = tracerOnOff (traceGsm trSel) verb "GSM" tr
    , Consensus.csjTracer = tracerOnOff (traceCsj trSel) verb "CSJ" tr
    , Consensus.dbfTracer = tracerOnOff (traceDevotedBlockFetch trSel) verb "DevotedBlockFetch" tr
    }
 where
   mkForgeTracers :: IO ForgeTracers
   mkForgeTracers = do
     -- We probably don't want to pay the extra IO cost per-counter-increment. -- sk
     metaCritical <- mkLOMeta Critical Confidential
     metaInfo <- mkLOMeta Info Public
     metaError <- mkLOMeta Error Public
     let name :: LoggerName = "metrics.Forge"
     ForgeTracers
       <$> counting (liftCounting metaInfo     name "forged"                   tr)
       <*> counting (liftCounting metaInfo     name "forge-about-to-lead"      tr)
       <*> counting (liftCounting metaError    name "could-not-forge"          tr)
       <*> counting (liftCounting metaInfo     name "adopted"                  tr)
       <*> counting (liftCounting metaError    name "didnt-adopt"              tr)
       <*> counting (liftCounting metaError    name "forged-invalid"           tr)
       <*> counting (liftCounting metaInfo     name "node-not-leader"          tr)
       <*> counting (liftCounting metaError    name "cannot-forge"             tr)
       <*> counting (liftCounting metaCritical name "forge-state-update-error" tr)
       <*> counting (liftCounting metaError    name "block-from-future"        tr)
       <*> counting (liftCounting metaError    name "slot-is-immutable"        tr)
       <*> counting (liftCounting metaInfo     name "node-is-leader"           tr)
       <*> counting (liftCounting metaError    name "adoption-thread-died"     tr)

   traceServedCount :: Maybe EKGDirect -> TraceChainSyncServerEvent blk -> IO ()
   traceServedCount Nothing _ = pure ()
   traceServedCount (Just ekgDirect) ev =
     when (isRollForward ev) $
       sendEKGDirectCounter ekgDirect
                            "cardano.node.metrics.served.header.counter.int"


traceBlockFetchServerMetrics
  :: forall blk peer. ()
  => Tracer IO (LoggerName, LogObject Text)
  -> LOMeta
  -> STM.TVar Int64
  -> STM.TVar Int64
  -> STM.TVar SlotNo
  -> Tracer IO (TraceLabelPeer peer (TraceBlockFetchServerEvent blk))
  -> Tracer IO (TraceLabelPeer peer (TraceBlockFetchServerEvent blk))
traceBlockFetchServerMetrics trMeta meta tBlocksServed tLocalUp tMaxSlotNo tracer = Tracer bfsTracer

  where
    bfsTracer :: TraceLabelPeer peer (TraceBlockFetchServerEvent blk) -> IO ()
    bfsTracer e@(TraceLabelPeer _p (TraceBlockFetchServerSendBlock p)) = do
      traceWith tracer e

      (served, mbLocalUpstreamyness) <- atomically $ do
          served <- STM.modifyReadTVar' tBlocksServed (+1)
          maxSlotNo <- STM.readTVar tMaxSlotNo
          case pointSlot p of
               Origin    -> return (served, Nothing)
               At slotNo ->
                   case compare maxSlotNo slotNo of
                        LT -> do
                            STM.writeTVar tMaxSlotNo slotNo
                            lu <- STM.modifyReadTVar' tLocalUp (+1)
                            return (served, Just lu)
                        GT -> do
                            return (served, Nothing)
                        EQ -> do
                            lu <- STM.modifyReadTVar' tLocalUp (+1)
                            return (served, Just lu)

      traceI trMeta meta "served.block.count" served
      forM_ mbLocalUpstreamyness $ \localUpstreamyness ->
          traceI trMeta meta "served.block.latest.count" localUpstreamyness


-- | CdfCounter tracks the number of time a value below 'limit' has been seen.
newtype CdfCounter (limit :: Nat) = CdfCounter Int64

-- | Estimates the CDF for a specific limit 'l' by counting the number of times
-- a value 'v' is below the limit.
cdfCounter :: forall a l.
               ( Num a, Ord a
               , KnownNat l)
            => a -> Int -> Int64 -> STM.TVar (CdfCounter l) -> STM Double
cdfCounter v !size !step tCdf= do
    when (v < lim) $
        STM.modifyTVar' tCdf (\(CdfCounter c) -> CdfCounter $ c + step)

    (CdfCounter cdf) <- STM.readTVar tCdf
    return $! (fromIntegral cdf / fromIntegral size)

  where
    lim :: a
    lim = fromInteger $ natVal (Proxy :: Proxy l)


-- Add an observation to the CdfCounter.
incCdfCounter :: Ord a => Num a => KnownNat l => a -> Int -> STM.TVar (CdfCounter l) -> STM Double
incCdfCounter v size = cdfCounter v size 1

-- Remove an observation from the CdfCounter.
decCdfCounter :: Ord a => Num a => KnownNat l => a -> Int -> STM.TVar (CdfCounter l) -> STM Double
decCdfCounter v size = cdfCounter v size (-1)


-- Track the fraction of times forgeDelay was above 1s, 3s, and 5s.
-- Only the first sample per slot number is counted.
cdf135Counters
  :: Integral a
  => STM.TVar (IntPSQ a NominalDiffTime)
  -> STM.TVar (CdfCounter 1)
  -> STM.TVar (CdfCounter 3)
  -> STM.TVar (CdfCounter 5)
  -> a
  -> NominalDiffTime
  -> STM (Bool, Double, Double, Double)
cdf135Counters slotMapVar cdf1sVar cdf3sVar cdf5sVar slotNo forgeDelay = do
  slotMap <- STM.readTVar slotMapVar
  if Pq.null slotMap && forgeDelay > 20
     then return (False, 0, 0, 0) -- During startup wait until we are in sync
     else case Pq.lookup (fromIntegral slotNo) slotMap of
       Nothing -> do
         let slotMap' = Pq.insert (fromIntegral slotNo) slotNo forgeDelay slotMap
         if Pq.size slotMap' > 1080 -- TODO k/2, should come from config file
            then
              case Pq.minView slotMap' of
                   Nothing -> return (False, 0, 0, 0) -- Err. We just inserted an element!
                   Just (_, minSlotNo, minDelay, slotMap'') ->
                     if minSlotNo == slotNo
                        then return (False, 0, 0, 0) -- Nothing to do
                        else do
                          decCdfs minDelay (Pq.size slotMap'')
                          (cdf1s, cdf3s, cdf5s) <- incCdfs forgeDelay (Pq.size slotMap'')
                          STM.writeTVar slotMapVar slotMap''
                          return (True, cdf1s, cdf3s, cdf5s)
            else do
              (cdf1s, cdf3s, cdf5s) <- incCdfs forgeDelay (Pq.size slotMap')
              STM.writeTVar slotMapVar slotMap'
              -- Wait until we have at least 45 samples before we start providing
              -- cdf estimates.
              if Pq.size slotMap >= 45
                 then return (True, cdf1s, cdf3s, cdf5s)
                 else return (True, -1, -1, -1)

       Just _ -> return (False, 0, 0, 0) -- dupe, we only track the first

  where
    incCdfs :: NominalDiffTime -> Int -> STM (Double, Double, Double)
    incCdfs delay size = do
      cdf1s <- incCdfCounter delay size cdf1sVar
      cdf3s <- incCdfCounter delay size cdf3sVar
      cdf5s <- incCdfCounter delay size cdf5sVar
      return (cdf1s, cdf3s, cdf5s)

    decCdfs :: NominalDiffTime -> Int -> STM ()
    decCdfs delay size =
      decCdfCounter delay size cdf1sVar
       >> decCdfCounter delay size cdf3sVar
       >> decCdfCounter delay size cdf5sVar
       >> return ()

traceBlockFetchClientMetrics
  :: forall blk remotePeer.
     ( )
  => Maybe EKGDirect
  -> STM.TVar (IntPSQ Word64 NominalDiffTime)
  -> STM.TVar (CdfCounter 1)
  -> STM.TVar (CdfCounter 3)
  -> STM.TVar (CdfCounter 5)
  -> Tracer IO (TraceLabelPeer remotePeer (TraceFetchClientState (Header blk)))
  -> Tracer IO (TraceLabelPeer remotePeer (TraceFetchClientState (Header blk)))
traceBlockFetchClientMetrics Nothing _ _ _ _ tracer = tracer
traceBlockFetchClientMetrics (Just ekgDirect) slotMapVar cdf1sVar cdf3sVar cdf5sVar tracer = Tracer bfTracer

  where
    bfTracer :: TraceLabelPeer remotePeer (TraceFetchClientState (Header blk)) -> IO ()
    bfTracer e@(TraceLabelPeer _ (CompletedBlockFetch p _ _ _ delay blockSize)) = do
      traceWith tracer e
      case pointSlot p of
        Origin -> return () -- Nothing to do.
        At slotNo -> do
          (fresh, cdf1s, cdf3s, cdf5s) <- atomically $
              cdf135Counters slotMapVar cdf1sVar cdf3sVar cdf5sVar (slotMapKey slotNo) delay

          when fresh $ do
            -- TODO: Revisit ekg counter access once there is a faster way.
            sendEKGDirectDouble ekgDirect "cardano.node.metrics.blockfetchclient.blockdelay.s"
                $ realToFrac delay
            sendEKGDirectInt ekgDirect "cardano.node.metrics.blockfetchclient.blocksize"
               blockSize
            when (cdf1s >= 0) $
              sendEKGDirectDouble ekgDirect
                "cardano.node.metrics.blockfetchclient.blockdelay.cdfOne"
                cdf1s

            when (cdf3s >= 0) $
              sendEKGDirectDouble ekgDirect
                "cardano.node.metrics.blockfetchclient.blockdelay.cdfThree"
                cdf3s

            when (cdf5s >= 0) $
              sendEKGDirectDouble ekgDirect
                "cardano.node.metrics.blockfetchclient.blockdelay.cdfFive"
                cdf5s
            when (delay > 5) $
              sendEKGDirectCounter ekgDirect "cardano.node.metrics.blockfetchclient.lateblocks"

    bfTracer e =
      traceWith tracer e

    slotMapKey :: SlotNo -> Word64
    slotMapKey (SlotNo s) = s


traceLeadershipChecks ::
  forall blk
  . ( Consensus.RunNode blk
     , LedgerQueries blk
     )
  => ForgeTracers
  -> NodeKernelData blk
  -> TracingVerbosity
  -> Trace IO Text
  -> Tracer IO (WithSeverity (Consensus.TraceLabelCreds (Consensus.TraceForgeEvent blk)))
traceLeadershipChecks _ft nodeKern _tverb tr = Tracer $
  \(WithSeverity sev (Consensus.TraceLabelCreds creds event)) ->
    case event of
      Consensus.TraceStartLeadershipCheck slot -> do
        !query <- mapNodeKernelDataIO
                    (\nk ->
                       (,,)
                         <$> fmap (maybe 0 LedgerDB.ledgerTableSize) (ChainDB.getStatistics $ getChainDB nk)
                         <*> nkQueryLedger (ledgerDelegMapSize . ledgerState) nk
                         <*> nkQueryChain fragmentChainDensity nk)
                    nodeKern
        meta <- mkLOMeta sev Public
        fromSMaybe (pure ()) $
          query <&>
            \(utxoSize, delegMapSize, _) -> do
                traceCounter "utxoSize"     tr utxoSize
                traceCounter "delegMapSize" tr delegMapSize
        traceNamedObject (appendName "LeadershipCheck" tr)
          ( meta
          , LogStructured $ KeyMap.fromList $
            [("kind", String "TraceStartLeadershipCheck")
            ,("credentials", String creds)
            ,("slot", toJSON $ unSlotNo slot)]
            ++ fromSMaybe []
               (query <&>
                 \(utxoSize, delegMapSize, chainDensity) ->
                   [ ("utxoSize",     toJSON utxoSize)
                   , ("delegMapSize", toJSON delegMapSize)
                   , ("chainDensity", toJSON (fromRational chainDensity :: Float))
                   ])
          )
      _ -> pure ()

teeForge ::
  forall blk
  . ( Consensus.RunNode blk
     , ToObject (CannotForge blk)
     , ToObject (LedgerErr (LedgerState blk))
     , ToObject (OtherHeaderEnvelopeError blk)
     , ToObject (ValidationErr (BlockProtocol blk))
     , ToObject (ForgeStateUpdateError blk)
     )
  => ForgeTracers
  -> TracingVerbosity
  -> Trace IO Text
  -> Tracer IO (WithSeverity (Consensus.TraceLabelCreds (Consensus.TraceForgeEvent blk)))
teeForge ft tverb tr = Tracer $
 \ev@(WithSeverity sev (Consensus.TraceLabelCreds _creds event)) -> do
  flip traceWith (WithSeverity sev event) $ fanning $ \(WithSeverity _ e) ->
    case e of
      Consensus.TraceStartLeadershipCheck{} -> teeForge' (ftForgeAboutToLead ft)
      Consensus.TraceSlotIsImmutable{} -> teeForge' (ftTraceSlotIsImmutable ft)
      Consensus.TraceBlockFromFuture{} -> teeForge' (ftTraceBlockFromFuture ft)
      Consensus.TraceBlockContext{} -> nullTracer
      Consensus.TraceNoLedgerState{} -> teeForge' (ftCouldNotForge ft)
      Consensus.TraceLedgerState{} -> nullTracer
      Consensus.TraceNoLedgerView{} -> teeForge' (ftCouldNotForge ft)
      Consensus.TraceLedgerView{} -> nullTracer
      Consensus.TraceForgeStateUpdateError{} -> teeForge' (ftTraceForgeStateUpdateError ft)
      Consensus.TraceNodeCannotForge {} -> teeForge' (ftTraceNodeCannotForge ft)
      Consensus.TraceNodeNotLeader{} -> teeForge' (ftTraceNodeNotLeader ft)
      Consensus.TraceNodeIsLeader{} -> teeForge' (ftTraceNodeIsLeader ft)
      Consensus.TraceForgeTickedLedgerState{} -> nullTracer
      Consensus.TraceForgingMempoolSnapshot{} -> nullTracer
      Consensus.TraceForgedBlock{} -> teeForge' (ftForged ft)
      Consensus.TraceDidntAdoptBlock{} -> teeForge' (ftDidntAdoptBlock ft)
      Consensus.TraceForgedInvalidBlock{} -> teeForge' (ftForgedInvalid ft)
      Consensus.TraceAdoptedBlock{} -> teeForge' (ftAdopted ft)
      Consensus.TraceAdoptionThreadDied{} -> teeForge' (ftTraceAdoptionThreadDied ft)
  case event of
    Consensus.TraceStartLeadershipCheck _slot -> pure ()
    _ -> traceWith (toLogObject' tverb tr) ev

teeForge'
  :: Trace IO Text
  -> Tracer IO (WithSeverity (Consensus.TraceForgeEvent blk))
teeForge' tr =
  Tracer $ \(WithSeverity _ ev) -> do
    meta <- mkLOMeta Critical Confidential
    traceNamedObject (appendName "metrics" tr) . (meta,) $
      case ev of
        Consensus.TraceStartLeadershipCheck slot ->
          LogValue "aboutToLeadSlotLast" $ PureI $ fromIntegral $ unSlotNo slot
        Consensus.TraceSlotIsImmutable slot _tipPoint _tipBlkNo ->
          LogValue "slotIsImmutable" $ PureI $ fromIntegral $ unSlotNo slot
        Consensus.TraceBlockFromFuture slot _slotNo ->
          LogValue "blockFromFuture" $ PureI $ fromIntegral $ unSlotNo slot
        Consensus.TraceBlockContext slot _tipBlkNo _tipPoint ->
          LogValue "blockContext" $ PureI $ fromIntegral $ unSlotNo slot
        Consensus.TraceNoLedgerState slot _ ->
          LogValue "couldNotForgeSlotLast" $ PureI $ fromIntegral $ unSlotNo slot
        Consensus.TraceLedgerState slot _ ->
          LogValue "ledgerState" $ PureI $ fromIntegral $ unSlotNo slot
        Consensus.TraceNoLedgerView slot _ ->
          LogValue "couldNotForgeSlotLast" $ PureI $ fromIntegral $ unSlotNo slot
        Consensus.TraceLedgerView slot ->
          LogValue "ledgerView" $ PureI $ fromIntegral $ unSlotNo slot
        Consensus.TraceForgeStateUpdateError slot _reason ->
          LogValue "forgeStateUpdateError" $ PureI $ fromIntegral $ unSlotNo slot
        Consensus.TraceNodeCannotForge slot _reason ->
          LogValue "nodeCannotForge" $ PureI $ fromIntegral $ unSlotNo slot
        Consensus.TraceNodeNotLeader slot ->
          LogValue "nodeNotLeader" $ PureI $ fromIntegral $ unSlotNo slot
        Consensus.TraceNodeIsLeader slot ->
          LogValue "nodeIsLeader" $ PureI $ fromIntegral $ unSlotNo slot
        Consensus.TraceForgeTickedLedgerState slot _prevPt ->
          LogValue "forgeTickedLedgerState" $ PureI $ fromIntegral $ unSlotNo slot
        Consensus.TraceForgingMempoolSnapshot slot _prevPt _mpHash _mpSlotNo ->
          LogValue "forgingMempoolSnapshot" $ PureI $ fromIntegral $ unSlotNo slot
        Consensus.TraceForgedBlock slot _ _ _ ->
          LogValue "forgedSlotLast" $ PureI $ fromIntegral $ unSlotNo slot
        Consensus.TraceDidntAdoptBlock slot _ ->
          LogValue "notAdoptedSlotLast" $ PureI $ fromIntegral $ unSlotNo slot
        Consensus.TraceForgedInvalidBlock slot _ _ ->
          LogValue "forgedInvalidSlotLast" $ PureI $ fromIntegral $ unSlotNo slot
        Consensus.TraceAdoptedBlock slot _ _ ->
          LogValue "adoptedSlotLast" $ PureI $ fromIntegral $ unSlotNo slot
        Consensus.TraceAdoptionThreadDied slot _ ->
          LogValue "adoptionThreadDied" $ PureI $ fromIntegral $ unSlotNo slot

forgeTracer
  :: forall blk.
     ( Consensus.RunNode blk
     , ToObject (CannotForge blk)
     , ToObject (LedgerErr (LedgerState blk))
     , ToObject (OtherHeaderEnvelopeError blk)
     , ToObject (ValidationErr (BlockProtocol blk))
     , ToObject (ForgeStateUpdateError blk)
     , HasKESInfo blk
     )
  => TracingVerbosity
  -> Trace IO Text
  -> ForgeTracers
  -> ForgingStats
  -> Tracer IO (Consensus.TraceLabelCreds (Consensus.TraceForgeEvent blk))
forgeTracer verb tr forgeTracers fStats =
  Tracer $ \tlcev@(Consensus.TraceLabelCreds _ ev) -> do
    -- Ignoring the credentials label for measurement and counters:
    traceWith (notifyBlockForging fStats tr) ev
    -- Consensus tracer -- here we track the label:
    traceWith (annotateSeverity
                 $ teeForge forgeTracers verb
                 $ appendName "Forge" tr) tlcev
    traceKESInfoIfKESExpired ev
 where
  traceKESInfoIfKESExpired ev =
    case ev of
      Consensus.TraceForgeStateUpdateError _ reason ->
        -- KES-key cannot be evolved, but anyway trace KES-values.
        case getKESInfo (Proxy @blk) reason of
          Nothing -> pure ()
          Just kesInfo -> do
            let logValues :: [LOContent a]
                logValues =
                  [ LogValue "operationalCertificateStartKESPeriod"
                      $ PureI . fromIntegral . unKESPeriod . HotKey.kesStartPeriod $ kesInfo
                  , LogValue "operationalCertificateExpiryKESPeriod"
                      $ PureI . fromIntegral . unKESPeriod . HotKey.kesEndPeriod $ kesInfo
                  , LogValue "currentKESPeriod"
                      $ PureI 0
                  , LogValue "remainingKESPeriods"
                      $ PureI 0
                  ]
            meta <- mkLOMeta Critical Confidential
            mapM_ (traceNamedObject (appendName "metrics" tr) . (meta,)) logValues
      _ -> pure ()

notifyBlockForging
  :: ForgingStats
  -> Trace IO Text
  -> Tracer IO (Consensus.TraceForgeEvent blk)
notifyBlockForging fStats tr = Tracer $ \case
  Consensus.TraceNodeCannotForge {} ->
    traceCounter "nodeCannotForge" tr
      =<< mapForgingCurrentThreadStats fStats
            (\fts -> (fts { ftsNodeCannotForgeNum = ftsNodeCannotForgeNum fts + 1 },
                       ftsNodeCannotForgeNum fts + 1))
  (Consensus.TraceNodeIsLeader (SlotNo slot')) -> do
    let slot = fromIntegral slot'
    traceCounter "nodeIsLeaderNum" tr
      =<< mapForgingCurrentThreadStats fStats
            (\fts -> (fts { ftsNodeIsLeaderNum = ftsNodeIsLeaderNum fts + 1
                          , ftsLastSlot = slot },
                      ftsNodeIsLeaderNum fts + 1))
  Consensus.TraceForgedBlock {} -> do
    traceCounter "blocksForgedNum" tr
      =<< mapForgingCurrentThreadStats fStats
            (\fts -> (fts { ftsBlocksForgedNum = ftsBlocksForgedNum fts + 1 },
                       ftsBlocksForgedNum fts + 1))

  Consensus.TraceNodeNotLeader (SlotNo slot') -> do
    -- Not is not a leader again, so now the number of blocks forged by this node
    -- should be equal to the number of slots when this node was a leader.
    let slot = fromIntegral slot'
    hasMissed <-
      mapForgingCurrentThreadStats fStats
        (\fts ->
          if ftsLastSlot fts == 0 || succ (ftsLastSlot fts) == slot then
            (fts { ftsLastSlot = slot }, False)
          else
            let missed = ftsSlotsMissedNum fts + (slot - ftsLastSlot fts)
            in (fts { ftsLastSlot = slot, ftsSlotsMissedNum = missed }, True))
    when hasMissed $ do
      x <- sum <$> threadStatsProjection fStats ftsSlotsMissedNum
      traceCounter "slotsMissedNum" tr x
  _ -> pure ()


--------------------------------------------------------------------------------
-- Mempool Tracers
--------------------------------------------------------------------------------

notifyTxsProcessed :: ForgingStats -> Trace IO Text -> Tracer IO (TraceEventMempool blk)
notifyTxsProcessed fStats tr = Tracer $ \case
  TraceMempoolRemoveTxs [] _ -> return ()
  TraceMempoolRemoveTxs txs _ -> do
    -- TraceMempoolRemoveTxs are previously valid transactions that are no longer valid because of
    -- changes in the ledger state. These transactions are already removed from the mempool,
    -- so we can treat them as completely processed.
    updatedTxProcessed <- mapForgingStatsTxsProcessed fStats (+ (length txs))
    traceCounter "txsProcessedNum" tr (fromIntegral updatedTxProcessed)
  TraceMempoolSynced (FallingEdgeWith duration) -> do
    traceCounter "txsSyncDuration" tr (round $ 1000 * duration :: Int)

  -- The rest of the constructors.
  _ -> return ()


mempoolMetricsTraceTransformer :: Trace IO a -> Tracer IO (TraceEventMempool blk)
mempoolMetricsTraceTransformer tr = Tracer $ \mempoolEvent -> do
  let tr' = appendName "metrics" tr
      (_n, tot_m) = case mempoolEvent of
                    TraceMempoolAddedTx     _tx0 _ tot0 -> (1, Just tot0)
                    TraceMempoolRejectedTx  _tx0 _ tot0 -> (1, Just tot0)
                    TraceMempoolRemoveTxs   txs0   tot0 -> (length txs0, Just tot0)
                    TraceMempoolManuallyRemovedTxs txs0 txs1 tot0 -> ( length txs0 + length txs1, Just tot0)
                    TraceMempoolSynced _ -> (0, Nothing)
                    _ -> (0, Nothing)
  case tot_m of
    Just tot -> do
      let logValue1 :: LOContent a
          logValue1 = LogValue "txsInMempool" $ PureI $ fromIntegral (msNumTxs tot)
          logValue2 :: LOContent a
          logValue2 = LogValue "mempoolBytes" . PureI . fromIntegral . unByteSize32 . msNumBytes $ tot
      meta <- mkLOMeta Critical Confidential
      traceNamedObject tr' (meta, logValue1)
      traceNamedObject tr' (meta, logValue2)
    Nothing -> return ()

mempoolTracer
  :: ( ToJSON (GenTxId blk)
     , ToObject (ApplyTxErr blk)
     , ToObject (GenTx blk)
     , LedgerSupportsMempool blk
     , ConvertRawHash blk
     )
  => TraceSelection
  -> Trace IO Text
  -> ForgingStats
  -> Tracer IO (TraceEventMempool blk)
mempoolTracer tc tracer fStats = Tracer $ \ev -> do
    traceWith (mempoolMetricsTraceTransformer tracer) ev
    traceWith (notifyTxsProcessed fStats tracer) ev
    let tr = appendName "Mempool" tracer
    traceWith (mpTracer tc tr) ev

mpTracer :: ( ToJSON (GenTxId blk)
            , ToObject (ApplyTxErr blk)
            , ToObject (GenTx blk)
            , ConvertRawHash blk
            , LedgerSupportsMempool blk
            )
         => TraceSelection -> Trace IO Text -> Tracer IO (TraceEventMempool blk)
mpTracer tc tr = annotateSeverity $ toLogObject' (traceVerbosity tc) tr

--------------------------------------------------------------------------------
-- ForgeStateInfo Tracers
--------------------------------------------------------------------------------

forgeStateInfoMetricsTraceTransformer
  :: forall a blk. HasKESMetricsData blk
  => Proxy blk
  -> Trace IO a
  -> Tracer IO (Consensus.TraceLabelCreds (ForgeStateInfo blk))
forgeStateInfoMetricsTraceTransformer p tr = Tracer $
  \(Consensus.TraceLabelCreds _ forgeStateInfo) -> do
    case getKESMetricsData p forgeStateInfo of
      NoKESMetricsData -> pure ()
      TPraosKESMetricsData kesPeriodOfKey
                           (MaxKESEvolutions maxKesEvos)
                           (OperationalCertStartKESPeriod oCertStartKesPeriod) -> do
        let metricsTr = appendName "metrics" tr

            -- The KES period of the hot key is relative to the start KES
            -- period of the operational certificate.
            currentKesPeriod = oCertStartKesPeriod + kesPeriodOfKey

            oCertExpiryKesPeriod = oCertStartKesPeriod + fromIntegral maxKesEvos

            kesPeriodsUntilExpiry =
              max 0 (oCertExpiryKesPeriod - currentKesPeriod)

            logValues :: [LOContent a]
            logValues =
              [ LogValue "operationalCertificateStartKESPeriod"
                  $ PureI
                  $ fromIntegral oCertStartKesPeriod
              , LogValue "operationalCertificateExpiryKESPeriod"
                  $ PureI
                  $ fromIntegral oCertExpiryKesPeriod
              , LogValue "currentKESPeriod"
                  $ PureI
                  $ fromIntegral currentKesPeriod
              , LogValue "remainingKESPeriods"
                  $ PureI
                  $ fromIntegral kesPeriodsUntilExpiry
              ]

        metaInfo <- mkLOMeta Info Public
        mapM_ (traceNamedObject metricsTr . (metaInfo,)) logValues

        -- Trace warning messages on the last 7 KES periods and, in the
        -- final and subsequent KES periods, trace alert messages.
        metaWarning <- mkLOMeta Warning Public
        metaAlert <- mkLOMeta Alert Public
        traceWith tr
          ( mempty
          , LogObject
              mempty
              (if kesPeriodsUntilExpiry > 7
               then metaInfo
                else if kesPeriodsUntilExpiry > 1
                     then metaWarning
                     else metaAlert
              )
              (LogStructuredText mempty (expiryLogMessage kesPeriodsUntilExpiry))
          )
  where
    expiryLogMessage :: Word -> Text
    expiryLogMessage kesPeriodsUntilExpiry =
      "Operational key will expire in "
        <> (Text.pack . show) kesPeriodsUntilExpiry
        <> " KES periods."

forgeStateInfoTracer
  :: forall blk.
     ( HasKESMetricsData blk
     , Show (ForgeStateInfo blk)
     )
  => Proxy blk
  -> TraceSelection
  -> Trace IO Text
  -> Tracer IO (Consensus.TraceLabelCreds (ForgeStateInfo blk))
forgeStateInfoTracer p _ts tracer = Tracer $ \ev -> do
    let tr = appendName "Forge" tracer
    traceWith (forgeStateInfoMetricsTraceTransformer p tracer) ev
    traceWith (fsTracer tr) ev
  where
    fsTracer :: Trace IO Text -> Tracer IO (Consensus.TraceLabelCreds (ForgeStateInfo blk))
    fsTracer tr = showTracing $ contramap Text.pack $ toLogObject tr

--------------------------------------------------------------------------------
-- NodeToClient Tracers
--------------------------------------------------------------------------------

nodeToClientTracers'
  :: forall blk localPeer.
     ( HasPrivacyAnnotation (Stateful.TraceSendRecv (LocalStateQuery blk (Point blk) (Query blk)) LocalStateQuery.State)
     , HasSeverityAnnotation (Stateful.TraceSendRecv (LocalStateQuery blk (Point blk) (Query blk)) LocalStateQuery.State)
     , ToObject (Stateful.TraceSendRecv (LocalStateQuery blk (Point blk) (Query blk)) LocalStateQuery.State)
     , forall fp. ShowQuery (BlockQuery blk fp)
     , ToObject localPeer
     )
  => TraceSelection
  -> TracingVerbosity
  -> Trace IO Text
  -> NodeToClient.Tracers' localPeer blk DeserialiseFailure (Tracer IO)
nodeToClientTracers' trSel verb tr =
  NodeToClient.Tracers
  { NodeToClient.tChainSyncTracer =
      tracerOnOff (traceLocalChainSyncProtocol trSel)
                  verb "LocalChainSyncProtocol" tr
  , NodeToClient.tTxMonitorTracer =
      tracerOnOff (traceLocalTxMonitorProtocol trSel)
                  verb "LocalTxMonitorProtocol" tr
  , NodeToClient.tTxSubmissionTracer =
      tracerOnOff (traceLocalTxSubmissionProtocol trSel)
                  verb "LocalTxSubmissionProtocol" tr
  , NodeToClient.tStateQueryTracer =
      tracerOnOff (traceLocalStateQueryProtocol trSel)
                  verb "LocalStateQueryProtocol" tr
  }

--------------------------------------------------------------------------------
-- NodeToNode Tracers
--------------------------------------------------------------------------------

nodeToNodeTracers'
  :: ( Consensus.RunNode blk
     , ConvertTxId blk
     , HasTxs blk
     , Show addr
     , ToObject (ConnectionId addr)
     , ToJSON addr
     )
  => TraceSelection
  -> TracingVerbosity
  -> Trace IO Text
  -> NodeToNode.Tracers IO addr blk DeserialiseFailure
nodeToNodeTracers' trSel verb tr =
  NodeToNode.Tracers
  { NodeToNode.tChainSyncTracer =
      tracerOnOff (traceChainSyncProtocol trSel)
                  verb "ChainSyncProtocol" tr
  , NodeToNode.tChainSyncSerialisedTracer =
      showOnOff (traceChainSyncProtocol trSel)
                "ChainSyncProtocolSerialised" tr
  , NodeToNode.tBlockFetchTracer =
      tracerOnOff (traceBlockFetchProtocol trSel)
                  verb "BlockFetchProtocol" tr
  , NodeToNode.tBlockFetchSerialisedTracer =
      showOnOff (traceBlockFetchProtocolSerialised trSel)
                "BlockFetchProtocolSerialised" tr
  , NodeToNode.tTxSubmission2Tracer =
      tracerOnOff (traceTxSubmissionProtocol trSel)
                  verb "TxSubmissionProtocol" tr
  , NodeToNode.tKeepAliveTracer =
      tracerOnOff (traceKeepAliveProtocol trSel)
                  verb "KeepAliveProtocol" tr
  , NodeToNode.tPeerSharingTracer =
      tracerOnOff (tracePeerSharingProtocol trSel)
                  verb "PeerSharingPrototocol" tr
  }

-- TODO @ouroboros-network
teeTraceBlockFetchDecision
    :: ( Eq peer
       , Show peer
       , ToJSON peer
       , HasHeader blk
       , ConvertRawHash blk
       )
    => TracingVerbosity
    -> MVar (Maybe (WithSeverity [TraceLabelPeer peer (FetchDecision [Point (Header blk)])]),Integer)
    -> Trace IO Text
    -> Tracer IO (WithSeverity (TraceDecisionEvent peer (Header blk)))
teeTraceBlockFetchDecision verb eliding tr =
  Tracer $ \(WithSeverity s ev) -> case ev of
    PeerStarvedUs {} -> do
      traceWith (toLogObject' verb meTr) ev
    PeersFetch ev' -> do
      traceWith (teeTraceBlockFetchDecision' meTr) (WithSeverity s ev')
      traceWith (teeTraceBlockFetchDecisionElide verb eliding bfdTr) (WithSeverity s ev')
 where
   meTr  = appendName "metrics" tr
   bfdTr = appendName "BlockFetchDecision" tr

teeTraceBlockFetchDecision'
    :: Trace IO Text
    -> Tracer IO (WithSeverity [TraceLabelPeer peer (FetchDecision [Point (Header blk)])])
teeTraceBlockFetchDecision' tr =
    Tracer $ \(WithSeverity _ peers) -> do
      meta <- mkLOMeta Info Confidential
      let tr' = appendName "peers" tr
      traceNamedObject tr' (meta, LogValue "connectedPeers" . PureI $ fromIntegral $ length peers)

teeTraceBlockFetchDecisionElide
    :: ( Eq peer
       , Show peer
       , ToJSON peer
       , HasHeader blk
       , ConvertRawHash blk
       )
    => TracingVerbosity
    -> MVar (Maybe (WithSeverity [TraceLabelPeer peer (FetchDecision [Point (Header blk)])]),Integer)
    -> Trace IO Text
    -> Tracer IO (WithSeverity [TraceLabelPeer peer (FetchDecision [Point (Header blk)])])
teeTraceBlockFetchDecisionElide = elideToLogObject

--------------------------------------------------------------------------------
-- PeerSelection Tracers
--------------------------------------------------------------------------------

traceConnectionManagerTraceMetrics
    :: OnOff TraceConnectionManagerCounters
    -> Maybe EKGDirect
    -> Tracer IO (ConnectionManager.Trace peerAddr handlerTrace)
traceConnectionManagerTraceMetrics _             Nothing         = nullTracer
traceConnectionManagerTraceMetrics (OnOff False) _               = nullTracer
traceConnectionManagerTraceMetrics (OnOff True) (Just ekgDirect) = cmtTracer
  where
    cmtTracer :: Tracer IO (ConnectionManager.Trace peerAddr handlerTrace)
    cmtTracer = Tracer $ \case
      ConnectionManager.TrConnectionManagerCounters
          ConnectionManagerCounters {
            fullDuplexConns,
            duplexConns,
            unidirectionalConns,
            inboundConns,
            outboundConns
          } -> do
        sendEKGDirectInt ekgDirect
                         "cardano.node.metrics.connectionManager.fullDuplexConns"
                         fullDuplexConns
        sendEKGDirectInt ekgDirect
                         "cardano.node.metrics.connectionManager.duplexConns"
                         duplexConns
        sendEKGDirectInt ekgDirect
                         "cardano.node.metrics.connectionManager.unidirectionalConns"
                         unidirectionalConns
        sendEKGDirectInt ekgDirect
                         "cardano.node.metrics.connectionManager.incomingConns"
                         inboundConns
        sendEKGDirectInt ekgDirect
                         "cardano.node.metrics.connectionManager.outgoingConns"
                         outboundConns
      _ -> return ()


tracePeerSelectionTracerMetrics
    :: forall extraDebugState extraFlags extraPeers peeraddr.
       OnOff TracePeerSelection
    -> Maybe EKGDirect
    -> Tracer IO (Governor.TracePeerSelection extraDebugState extraFlags extraPeers peeraddr)
tracePeerSelectionTracerMetrics _             Nothing          = nullTracer
tracePeerSelectionTracerMetrics (OnOff False) _                = nullTracer
tracePeerSelectionTracerMetrics (OnOff True)  (Just ekgDirect) = pstTracer
  where
    pstTracer :: Tracer IO (Governor.TracePeerSelection extraDebugState extraFlags extraPeers peeraddr)
    pstTracer = Tracer $ \a -> do
      case a of
        Governor.TraceChurnAction duration action _ ->
          sendEKGDirectDouble
            ekgDirect
            ("cardano.node.metrics.peerSelection.churn." <> Text.pack (show action) <> ".duration")
            (realToFrac duration)
        _ -> pure ()


tracePeerSelectionCountersMetrics
    :: OnOff TracePeerSelectionCounters
    -> Maybe EKGDirect
    -> Tracer IO (PeerSelectionCounters (Cardano.ExtraPeerSelectionSetsWithSizes addr))
tracePeerSelectionCountersMetrics _             Nothing          = nullTracer
tracePeerSelectionCountersMetrics (OnOff False) _                = nullTracer
tracePeerSelectionCountersMetrics (OnOff True)  (Just ekgDirect) = pscTracer
  where
    pscTracer :: Tracer IO (PeerSelectionCounters (Cardano.ExtraPeerSelectionSetsWithSizes addr))
    pscTracer = Tracer $ \psc -> do
      let PeerSelectionCountersHWC {..} = psc
      -- Deprecated counters; they will be removed in a future version
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.cold" numberOfColdPeers
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.warm" numberOfWarmPeers
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.hot"  numberOfHotPeers
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.coldBigLedgerPeers" numberOfColdBigLedgerPeers
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.warmBigLedgerPeers" numberOfWarmBigLedgerPeers
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.hotBigLedgerPeers" numberOfHotBigLedgerPeers

      let PeerSelectionCounters {..} = psc
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.RootPeers" numberOfRootPeers

      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.KnownPeers" numberOfKnownPeers
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.ColdPeersPromotions" numberOfColdPeersPromotions
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.EstablishedPeers" numberOfEstablishedPeers
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.WarmPeersDemotions" numberOfWarmPeersDemotions
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.WarmPeersPromotions" numberOfWarmPeersPromotions
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.ActivePeers" numberOfActivePeers
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.ActivePeersDemotions" numberOfActivePeersDemotions


      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.KnownBigLedgerPeers" numberOfKnownBigLedgerPeers
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.ColdBigLedgerPeersPromotions" numberOfColdBigLedgerPeersPromotions
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.EstablishedBigLedgerPeers" numberOfEstablishedBigLedgerPeers
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.WarmBigLedgerPeersDemotions" numberOfWarmBigLedgerPeersDemotions
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.WarmBigLedgerPeersPromotions" numberOfWarmBigLedgerPeersPromotions
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.ActiveBigLedgerPeers" numberOfActiveBigLedgerPeers
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.ActiveBigLedgerPeersDemotions" numberOfActiveBigLedgerPeersDemotions

      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.KnownLocalRootPeers" numberOfKnownLocalRootPeers
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.EstablishedLocalRootPeers" numberOfEstablishedLocalRootPeers
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.WarmLocalRootPeersPromotions" numberOfWarmLocalRootPeersPromotions
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.ActiveLocalRootPeers" numberOfActiveLocalRootPeers
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.ActiveLocalRootPeersDemotions" numberOfActiveLocalRootPeersDemotions

      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.KnownNonRootPeers" numberOfKnownNonRootPeers
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.ColdNonRootPeersPromotions" numberOfColdNonRootPeersPromotions
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.EstablishedNonRootPeers" numberOfEstablishedNonRootPeers
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.WarmNonRootPeersDemotions" numberOfWarmNonRootPeersDemotions
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.WarmNonRootPeersPromotions" numberOfWarmNonRootPeersPromotions
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.ActiveNonRootPeers" numberOfActiveNonRootPeers
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.ActiveNonRootPeersDemotions" numberOfActiveNonRootPeersDemotions

      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.KnownBootstrapPeers" (snd $ Cardano.viewKnownBootstrapPeers extraCounters)
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.ColdBootstrapPeersPromotions" (snd $ Cardano.viewColdBootstrapPeersPromotions extraCounters)
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.EstablishedBootstrapPeers" (snd $ Cardano.viewEstablishedBootstrapPeers extraCounters)
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.WarmBootstrapPeersDemotions" (snd $ Cardano.viewWarmBootstrapPeersDemotions extraCounters)
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.WarmBootstrapPeersPromotions" (snd $ Cardano.viewWarmBootstrapPeersPromotions extraCounters)
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.ActiveBootstrapPeers" (snd $ Cardano.viewActiveBootstrapPeers extraCounters)
      sendEKGDirectInt ekgDirect "cardano.node.metrics.peerSelection.ActiveBootstrapPeersDemotions" (snd $ Cardano.viewActiveBootstrapPeersDemotions extraCounters)


traceChurnCountersMetrics
    :: Maybe EKGDirect
    -> Tracer IO ChurnCounters
traceChurnCountersMetrics Nothing = nullTracer
traceChurnCountersMetrics (Just ekgDirect) = churnTracer
  where
    churnTracer :: Tracer IO ChurnCounters
    churnTracer = Tracer $ \(ChurnCounter action c) ->
      sendEKGDirectInt ekgDirect ("cardano.node.metrics.peerSelection.churn." <> Text.pack (show action)) c


traceInboundGovernorCountersMetrics
    :: forall addr.
       OnOff TraceInboundGovernorCounters
    -> Maybe EKGDirect
    -> Tracer IO (InboundGovernor.Trace addr)
traceInboundGovernorCountersMetrics _             Nothing         = nullTracer
traceInboundGovernorCountersMetrics (OnOff False) _               = nullTracer
traceInboundGovernorCountersMetrics (OnOff True) (Just ekgDirect) = ipgcTracer
  where
    ipgcTracer :: Tracer IO (InboundGovernor.Trace addr)
    ipgcTracer = Tracer $ \case
      (InboundGovernor.TrInboundGovernorCounters InboundGovernor.Counters {
          idlePeersRemote,
          coldPeersRemote,
          warmPeersRemote,
          hotPeersRemote
        }) -> do
          sendEKGDirectInt ekgDirect "cardano.node.metrics.inboundGovernor.idle"
                                     idlePeersRemote
          sendEKGDirectInt ekgDirect "cardano.node.metrics.inboundGovernor.cold"
                                     coldPeersRemote
          sendEKGDirectInt ekgDirect "cardano.node.metrics.inboundGovernor.warm"
                                     warmPeersRemote
          sendEKGDirectInt ekgDirect "cardano.node.metrics.inboundGovernor.hot"
                                     hotPeersRemote
      _ -> return ()


-- | get information about a chain fragment

data ChainInformation = ChainInformation
  { slots :: Word64
  , blocks :: Word64
  , density :: Rational
    -- ^ the actual number of blocks created over the maximum expected number
    -- of blocks that could be created over the span of the last @k@ blocks.
  , epoch :: EpochNo
    -- ^ In which epoch is the tip of the current chain
  , slotInEpoch :: Word64
    -- ^ Relative slot number of the tip of the current chain within the
    -- epoch.
  , blocksUncoupledDelta :: Int64
    -- ^ The net change in number of blocks forged since last restart not on the
    -- current chain.
  , fork :: Bool
    -- ^ Was this a fork.
  , tipBlockHash :: Text
    -- ^ Hash of the last adopted block.
  , tipBlockParentHash :: Text
    -- ^ Hash of the parent block of the last adopted block.
  , tipBlockIssuerVerificationKeyHash :: BlockIssuerVerificationKeyHash
    -- ^ Hash of the last adopted block issuer's verification key.
  }

chainInformation
  :: forall blk. ()
  => HasHeader (Header blk)
  => HasIssuer blk
  => ConvertRawHash blk
  => ChainDB.SelectionChangedInfo blk
  -> Bool
  -> AF.AnchoredFragment (Header blk) -- ^ Old fragment.
  -> AF.AnchoredFragment (Header blk) -- ^ New fragment.
  -> Int64
  -> ChainInformation
chainInformation selChangedInfo fork oldFrag frag blocksUncoupledDelta = ChainInformation
    { slots = unSlotNo $ fromWithOrigin 0 (AF.headSlot frag)
    , blocks = unBlockNo $ fromWithOrigin (BlockNo 1) (AF.headBlockNo frag)
    , density = fragmentChainDensity frag
    , epoch = ChainDB.newTipEpoch selChangedInfo
    , slotInEpoch = ChainDB.newTipSlotInEpoch selChangedInfo
    , blocksUncoupledDelta = blocksUncoupledDelta
    , fork = fork
    , tipBlockHash = renderHeaderHash (Proxy @blk) $ realPointHash (ChainDB.newTipPoint selChangedInfo)
    , tipBlockParentHash = renderChainHash (Text.decodeLatin1 . B16.encode . toRawHash (Proxy @blk)) $ AF.headHash oldFrag
    , tipBlockIssuerVerificationKeyHash = tipIssuerVkHash
    }
  where
    tipIssuerVkHash :: BlockIssuerVerificationKeyHash
    tipIssuerVkHash =
      case AF.head frag of
        Left AF.AnchorGenesis ->
          NoBlockIssuer
        Left (AF.Anchor _s _h _b) ->
          NoBlockIssuer
        Right blk -> getIssuerVerificationKeyHash blk

fragmentChainDensity ::
  HasHeader (Header blk)
  => AF.AnchoredFragment (Header blk) -> Rational
fragmentChainDensity frag = calcDensity blockD slotD
  where
    calcDensity :: Word64 -> Word64 -> Rational
    calcDensity bl sl
      | sl > 0 = toRational bl / toRational sl
      | otherwise = 0
    slotN  = unSlotNo $ fromWithOrigin 0 (AF.headSlot frag)
    -- Slot of the tip - slot @k@ blocks back. Use 0 as the slot for genesis
    -- includes EBBs
    slotD   = slotN
            - unSlotNo (fromWithOrigin 0 (AF.lastSlot frag))
    -- Block numbers start at 1. We ignore the genesis EBB, which has block number 0.
    blockD = blockN - firstBlock
    blockN = unBlockNo $ fromWithOrigin (BlockNo 1) (AF.headBlockNo frag)
    firstBlock = case unBlockNo . blockNo <$> AF.last frag of
      -- Empty fragment, no blocks. We have that @blocks = 1 - 1 = 0@
      Left _  -> 1
      -- The oldest block is the genesis EBB with block number 0,
      -- don't let it contribute to the number of blocks
      Right 0 -> 1
      Right b -> b


--------------------------------------------------------------------------------
-- Trace Helpers
--------------------------------------------------------------------------------

readableTraceBlockchainTimeEvent :: TraceBlockchainTimeEvent UTCTime -> Text
readableTraceBlockchainTimeEvent ev = case ev of
    TraceStartTimeInTheFuture (SystemStart start) toWait ->
      "Waiting " <> (Text.pack . show) toWait <> " until genesis start time at " <> (Text.pack . show) start
    TraceCurrentSlotUnknown time _ ->
      "Too far from the chain tip to determine the current slot number for the time "
       <> (Text.pack . show) time
    TraceSystemClockMovedBack prevTime newTime ->
      "The system wall clock time moved backwards, but within our tolerance "
      <> "threshold. Previous 'current' time: " <> (Text.pack . show) prevTime
      <> ". New 'current' time: " <> (Text.pack . show) newTime

tracerOnOff :: Transformable Text IO a
            => OnOff b
            -> TracingVerbosity
            -> LoggerName
            -> Trace IO Text
            -> Tracer IO a
tracerOnOff (OnOff False) _ _ _ = nullTracer
tracerOnOff (OnOff True) verb name trcer = annotateSeverity
                                        $ toLogObject' verb
                                        $ appendName name trcer

tracerOnOff'
  :: OnOff b -> Tracer IO a -> Tracer IO a
tracerOnOff' (OnOff False) _ = nullTracer
tracerOnOff' (OnOff True) tr = tr

instance Show a => Show (WithSeverity a) where
  show (WithSeverity _sev a) = show a

showOnOff
  :: (Show a, HasSeverityAnnotation a)
  => OnOff b -> LoggerName -> Trace IO Text -> Tracer IO a
showOnOff (OnOff False) _ _ = nullTracer
showOnOff (OnOff True) name trcer = annotateSeverity
                                        $ showTracing
                                        $ withName name trcer

withName :: Text -> Trace IO Text -> Tracer IO String
withName name tr = contramap Text.pack $ toLogObject $ appendName name tr
