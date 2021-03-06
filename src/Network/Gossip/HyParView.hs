{-# LANGUAGE ConstraintKinds  #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes       #-}
{-# LANGUAGE TypeFamilies     #-}

-- |
-- Copyright   : 2018 Monadic GmbH
-- License     : BSD3
-- Maintainer  : kim@monadic.xyz, team@monadic.xyz
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--
-- Implementation of the HyParView membership protocol.
--
-- <http://asc.di.fct.unl.pt/~jleitao/pdf/dsn07-leitao.pdf>
--
-- The types are parametrised over a node identity @n@. Note that @n@ must carry
-- enough information to be able to establish a physical network connection (see
-- 'connOpen'). In order to impede both sybil and eclipse attacks, it is
-- advisable to also factor in a cryptographic node id. How to do that is beyond
-- the scope of this module.
module Network.Gossip.HyParView
    ( HasPeerNodeId (..)
    , HasPeerAddr (..)
    , HasPeer

    , Peers (active, passive)
    , getPeers

    , Env
    , envSelf
    , new

    , Config (..)
    , defaultConfig

    , RPC (..)
    , Message (..)
    , Priority (..)

    , Connection (..)
    , HyParViewC (..)

    , HyParView
    , runHyParView

    , getPeers'
    , activeView
    , passiveView

    , receive
    , eject
    , joinAny
    , joinFirst
    , shuffle
    , promoteRandom
    )
where

import           Network.Gossip.HyParView.Internal

import           Codec.Serialise (Serialise)
import           Control.Applicative (liftA2)
import           Control.Concurrent.STM
import           Control.Exception.Safe
                 ( Exception
                 , SomeException
                 , toException
                 , tryAny
                 )
import           Control.Monad (when)
import           Control.Monad.Reader
import           Control.Monad.Trans.Cont
import           Data.Bifunctor (first)
import           Data.Bool (bool)
import           Data.Foldable (foldlM, for_, traverse_)
import           Data.Hashable (Hashable)
import           Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as Map
import           Data.HashSet (HashSet)
import qualified Data.HashSet as Set
import           Data.IORef (IORef, atomicModifyIORef', newIORef)
import           Data.Maybe (listToMaybe)
import           Data.Traversable (for)
import           Data.Word (Word8)
import           GHC.Generics (Generic)
import           Lens.Micro (Lens')
import           Lens.Micro.Extras (view)
import           System.Random (randomR, split)
import           System.Random.SplitMix (SMGen)


class HasPeerNodeId a where
    type NodeId a
    peerNodeId :: Lens' a (NodeId a)

class HasPeerAddr a where
    type Addr a
    peerAddr :: Lens' a (Addr a)

type HasPeer a = (HasPeerNodeId a, HasPeerAddr a)

data Connection n = Connection
    { connPeer  :: n
    , connSend  :: RPC n -> IO ()
    , connClose :: IO ()
    }

data Peers n = Peers
    { active  :: HashSet n
    , passive :: HashSet n
    }

-- TODO: stm containers
data Env n = Env
    { envSelf    :: n
    , envConfig  :: Config
    , envPRNG    :: IORef SMGen
    , envActive  :: TVar (HashMap n (Connection n))
    , envPassive :: TVar (HashSet n)
    }

new :: (Eq n, Hashable n) => n -> Config -> SMGen -> IO (Env n)
new envSelf envConfig prng = do
    envPRNG    <- newIORef prng
    envActive  <- newTVarIO mempty
    envPassive <- newTVarIO mempty
    pure Env {..}

data Config = Config
    { -- | Maximum size of the active view.
      cfgMaxActive      :: Word8
      -- | Maximum size of the passive view.
    , cfgMaxPassive     :: Word8
      -- | Active Maximum Random Walk Length.
      --
      -- Specifies the maximum number of hops a 'ForwardJoin' rpc is propagated.
    , cfgARWL           :: Word8
      -- | Passive Maximum Random Walk Length.
      --
      -- Specifies the number of hops at which a node propagated via
      -- 'ForwardJoin' is inserted into the passive view.
    , cfgPRWL           :: Word8
      -- | Number of nodes from the active view to include in a 'Shuffle'
      -- request.
      --
      -- @ka@ in the paper.
    , cfgShuffleActive  :: Word8
      -- | Number of nodes from the passive view to include in a 'Shuffle'
      -- request.
      --
      -- @kp@ in the paper.
    , cfgShufflePassive :: Word8
    }

-- | Default 'Config' with values used for the paper.
defaultConfig :: Config
defaultConfig = Config
    { cfgMaxActive      = 5
    , cfgMaxPassive     = 30
    , cfgARWL           = 6
    , cfgPRWL           = 3
    , cfgShuffleActive  = 3
    , cfgShufflePassive = 4
    }

data RPC n = RPC
    { rpcSender    :: n
    , rpcRecipient :: n
    , rpcPayload   :: Message n
    } deriving (Eq, Generic)

instance (Serialise n, Eq n, Hashable n) => Serialise (RPC n)

data Message n =
      Join
    | ForwardJoin     n TimeToLive
    | Disconnect
    | Neighbor        Priority
    | NeighborReject
    | Shuffle         n (HashSet n) TimeToLive
    | ShuffleReply    (HashSet n)
    deriving (Eq, Generic)

instance (Serialise n, Eq n, Hashable n) => Serialise (Message n)

data Priority = Low | High
    deriving (Eq, Ord, Show, Generic)

instance Serialise Priority

-- Continuations ---------------------------------------------------------------

data HyParViewC n a =
      ConnectionOpen (Addr n)
                     (Maybe (NodeId n))
                     (Either SomeException (Connection n) -> IO (HyParViewC n a))
    | SendAdHoc      (RPC n) (IO (HyParViewC n a))
    | NeighborUp     n       (IO (HyParViewC n a))
    | NeighborDown   n       (IO (HyParViewC n a))
    | Done           a

connectionOpen
    :: Addr n
    -> Maybe (NodeId n)
    -> HyParView n (Either SomeException (Connection n))
connectionOpen addr nid =
    HyParView $ ReaderT $ \_ -> ContT $ \k ->
        pure $ ConnectionOpen addr nid k

sendAdHoc :: RPC n -> HyParView n ()
sendAdHoc rpc =
    HyParView $ ReaderT $ \_ -> ContT $ \k ->
        pure $ SendAdHoc rpc (k ())

neighborUp :: n -> HyParView n ()
neighborUp n =
    HyParView $ ReaderT $ \_ -> ContT $ \k ->
        pure $ NeighborUp n (k ())

neighborDown :: n -> HyParView n ()
neighborDown n =
    HyParView $ ReaderT $ \_ -> ContT $ \k ->
        pure $ NeighborDown n (k ())

-- Monad -----------------------------------------------------------------------

newtype HyParView n a = HyParView
    { fromHyParView :: forall x. ReaderT (Env n) (ContT (HyParViewC n x) IO) a
    } deriving Functor

instance Applicative (HyParView n) where
    pure x = HyParView $ pure x
    (<*>)  = ap

instance Monad (HyParView n) where
    return            = pure
    HyParView m >>= f = HyParView $ m >>= fromHyParView . f
    {-# INLINE (>>=) #-}

instance MonadIO (HyParView n) where
    liftIO io = HyParView $ liftIO io

instance MonadReader (Env n) (HyParView n) where
    ask       = HyParView $ ReaderT pure
    local f m = HyParView $ local f (fromHyParView m)

runHyParView :: Env n -> HyParView n a -> IO (HyParViewC n a)
runHyParView r (HyParView m) = runContT (runReaderT m r) (pure . Done)

-- API -------------------------------------------------------------------------

-- | Obtain the current active view.
--
-- This is part of the \"Peer Sampling Service\" interface as specified by the
-- plumtree paper.
getPeers :: (Eq n, Hashable n) => HyParView n (HashSet n)
getPeers = activeView

-- | Obtain a consistent snapshot of both the active and passive view.
getPeers' :: (Eq n, Hashable n) => HyParView n (Peers n)
getPeers' = do
    Env { envActive, envPassive } <- ask
    liftIO . atomically $
        liftA2 Peers (keysSet <$> readTVar envActive) (readTVar envPassive)

-- | Obtain a snapshot of the active view.
activeView :: (Eq n, Hashable n) => HyParView n (HashSet n)
activeView = asks envActive >>= liftIO . fmap keysSet . readTVarIO

-- | Obtain a snapshot of the passive view.
passiveView :: HyParView n (HashSet n)
passiveView = asks envPassive >>= liftIO . readTVarIO

-- | Env an incoming 'RPC' and return a (possibly empty) list of outgoing
-- 'RPC's.
--
-- Rethrows any exceptions raised by attempting to establish new connections.
receive :: (Eq n, Hashable n, HasPeer n) => RPC n -> HyParView n ()
receive RPC { rpcSender, rpcPayload } = case rpcPayload of
    Join -> do
        arwl <- asks (fromIntegral . cfgARWL . envConfig)
        void $ addToActive rpcSender
        broadcast $ ForwardJoin rpcSender arwl

    ForwardJoin joining ttl -> do
        self  <- asks envSelf
        nactv <- numActive
        if joining /= self && (isExpired ttl || nactv == 1) then do
            -- Notify the joining node of the endpoint of the random walk by
            -- sending it a 'Neighbor' request. This is an omission in the
            -- paper: the joining node cannot otherwise learn about having been
            -- added to some other node's active view, violating the
            -- symmetricity property of the active views.
            conn <- addToActive joining
            case conn of
                Left  _ -> eject joining
                Right c -> do
                    prio <- neighborPriority
                    sendTo c joining $ Neighbor prio
        else do
            prwl <- asks (fromIntegral . cfgPRWL . envConfig)
            when (ttl == prwl) $
                addToPassive joining
            sendAnyActive (ForwardJoin joining (decr ttl)) [joining]

    Disconnect -> do
        removeFromActive rpcSender >>= traverse_ (liftIO . connClose)
        addToPassive rpcSender
        -- Panic: if the network starts to 'Disconnect' us, actively seek to
        -- remain connected.
        nactv <- numActive
        unless (nactv > 1) $ do
            -- Try to promote a random passive node.
            rpn <- randomPassiveNodeNot rpcSender
            case rpn of
                -- Note: 'High' priority to ensure this actually succeeds (the
                -- same node could have rejected us before).
                Just n  -> do
                    conn <- addToActive n
                    case conn of
                        Left  _ -> eject n
                        Right c -> sendTo c n $ Neighbor High
                -- We ran out of passive nodes, ask the network for some fresh
                -- ones.
                Nothing -> shuffle

    Neighbor prio -> do
        full <- ask >>= liftIO . atomically . isActiveAtCapacity
        if prio == High || not full then
            void $ addToActive rpcSender
        else
            sendAdHoc =<< reply NeighborReject

    NeighborReject ->
        -- Deviation from the paper: we do _not_ add the rejecting node to the
        -- passive view here, as this can lead to a "death loop", where we just
        -- cycle through a set of nodes likely to reject us again. Instead, in
        -- 'eject', we initiate a 'shuffle' if we run out of peers (either
        -- active or passive) to increase our options.
        eject rpcSender

    Shuffle origin nodes ttl | Set.null nodes -> pure ()
                             | otherwise      -> do
        nactv <- numActive
        let ttl' = decr ttl
        if not (isExpired ttl') && nactv > 1 then
            sendAnyActive (Shuffle origin nodes ttl') mempty
        else do
            rpns <- randomPassiveNodes (Set.size nodes)
            addAllToPassive nodes
            sendAdHoc =<< mkRPC origin (ShuffleReply rpns)

    ShuffleReply nodes -> do
        addAllToPassive nodes
        -- Emergency: we may have issued a shuffle because we where running low
        -- on peers. Try to promote a random passive node if that's the case.
        nactv <- numActive
        when (nactv <= 1) promoteRandom
  where
    reply = mkRPC rpcSender

    sendAnyActive msg omit = do
        actv <- randomActiveNodeNot (Set.fromList (rpcSender:omit))
        for_ actv $ \(n, conn) -> sendTo conn n msg

    broadcast msg = do
        actv <- asks envActive >>= liftIO . readTVarIO
        void $
            Map.traverseWithKey
                (\n conn -> sendTo conn n msg)
                (Map.delete rpcSender actv)

-- | Eject a node suspected to be faulty from the active view.
--
-- If the node was not in the active view, does nothing, otherwise, tries to
-- promote a random node from the passive view by attempting to establish a
-- connection to it. If that succeeds, send it a 'Neighbor' RPC, which may
-- eventually lead to the node being promoted to the active view of the peer
-- (see 'receive'). Otherwise, removes that node from the passive view and tries
-- another.
--
-- Note that the paper does not specify whether the ejecting node @p@ should add
-- the to-be-promoted node @q@ to it's active view immediately after
-- successfully establishing a connection, or wait for some confirmation from
-- @q@. We opt to add it to the active view optimistically, and eject it again
-- if we receive a 'NeighborReject' from it. Consequentially,
--
--   * the component handling the sending of the 'RPC's should call 'eject' if
--   that doesn't succeed (which should mean that it can treat all sending
--   uniformly)
--   * the receiver of a 'Neighbor' 'RPC' wishing to reject the request should
--   close the connection on its end after replying with 'NeighborReject', such
--   that the node gets 'eject'ed on the requestor's side on the next attempt to
--   use the connection.
eject :: (Eq n, Hashable n, HasPeer n) => n -> HyParView n ()
eject n = do
    removeFromActive n >>= traverse_ (liftIO . connClose)
    promoteRandom
    nactv <- numActive
    -- Panic: initiate a 'shuffle' if we seem to run out of peers.
    when (nactv <= 1) shuffle

-- | Join the overlay by attempting to connect to the supplied contact nodes.
--
-- If the connection attempt succeeds, the contact node is added to the active
-- view, and a 'Join' rpc is placed in the returned list to be sent to that
-- contact.
--
-- All contacts (up to @cfgMaxActive + cfgMaxPassive@) will be tried,
-- left-to-right.
--
-- This should only be called once to boostrap the protocol, with empty 'Peers'.
-- This condition is, however, not checked nor enforced. Hence, the returned
-- list of 'RPC's may also contain 'Disconnect' messages due to evicted active
-- peers.
joinAny
    :: ( Eq         n
       , Eq (NodeId n)
       , Eq (Addr   n)
       , Hashable   n
       , HasPeer    n
       )
    => [(Maybe (NodeId n), Addr n)]
    -> HyParView n ()
joinAny contacts = do
    self <- asks envSelf
    Config { cfgMaxActive, cfgMaxPassive } <- asks envConfig
    traverse_ go
        . take (fromIntegral $ cfgMaxActive + cfgMaxPassive)
        . filter (\(n, addr) ->
            Just (view peerNodeId self) /= n && view peerAddr self /= addr)
        $ contacts
  where
    go (n, addr) = do
        conn <- connectionOpen addr n
        for_ conn $
                addConnectedToActive
            >=> traverse_ (\c -> sendTo c (connPeer c) Join)

-- | Like 'joinAny', but stop on the first successfully established connection.
joinFirst
    :: ( Eq         n
       , Eq (NodeId n)
       , Eq (Addr   n)
       , Hashable   n
       , HasPeer    n
       )
    => [(Maybe (NodeId n), Addr n)]
    -> HyParView n ()
joinFirst contacts = do
    self <- asks envSelf
    go $ filter (\(n, addr) ->
             Just (view peerNodeId self) /= n && view peerAddr self /= addr)
         contacts
  where
    go []               = pure ()
    go ((n, addr)  :xs) = do
        conn <- connectionOpen addr n
        case conn of
            Right c ->
                    addConnectedToActive c
                >>= traverse_ (\c' -> sendTo c' (connPeer c') Join)
            Left _  -> joinFirst xs

-- | Initiate a 'Shuffle'.
--
-- This is supposed to be called periodically in order to exchange peers with
-- the known part of the network.
shuffle :: (Eq n, Hashable n, HasPeer n) => HyParView n ()
shuffle = do
    Config { cfgARWL           = arwl
           , cfgShuffleActive  = ka
           , cfgShufflePassive = kp
           } <- asks envConfig

    s   <- asks envSelf
    ran <- randomActiveNode
    for_ ran $ \(r, rconn) -> do
        nodes <-
            liftA2 (<>)
                   (keysSet <$>
                       randomActiveNodesNot (Set.singleton r) (fromIntegral ka))
                   (randomPassiveNodes (fromIntegral kp))
        unless (Set.null nodes) $
            sendTo rconn r $ Shuffle s nodes (fromIntegral arwl)

-- Internal --------------------------------------------------------------------

-- | Select a node from the active view at random.
--
-- If the active view is empty, 'Nothing' is returned, otherwise 'Just' the
-- random node.
randomActiveNode :: (Eq n, Hashable n) => HyParView n (Maybe (n, Connection n))
randomActiveNode = randomActiveNodeNot mempty

-- | Select a node @n@, but not nodes @ns@, from the active view at random.
randomActiveNodeNot
    :: (Eq n, Hashable n)
    => HashSet n
    -> HyParView n (Maybe (n, Connection n))
randomActiveNodeNot ns = do
    Env { envPRNG, envActive } <- ask
    liftIO $ do
        prng <- atomicModifyIORef' envPRNG split
        atomically $ do
            actv <- readTVar envActive
            let
                actv'   = Set.difference (keysSet actv) ns
                (rnd,_) = randomFromSet actv' prng
              in
                pure $ rnd >>= \x -> (x,) <$> Map.lookup x actv

-- | Select 'num' nodes, but not nodes 'ns', from the active view at random.
--
-- If the active view is empty, the empty set is returned. 'num' is adjusted to
-- be:
--
-- > min (size active - size omitted) (min cfgMaxActive num)
randomActiveNodesNot
    :: (Eq n, Hashable n)
    => HashSet n
    -> Int
    -> HyParView n (HashMap n (Connection n))
randomActiveNodesNot ns num = do
    Env { envConfig, envActive } <- ask
    actv <- liftIO $ readTVarIO envActive
    let min' = min (Map.size actv - Set.size ns)
             . min num
             . fromIntegral
             . cfgMaxActive
             $ envConfig
    loop min' Map.empty
  where
    loop min' !s = do
        ran <- randomActiveNodeNot ns
        case ran of
            Nothing -> pure s
            Just (n', c) | s' <- Map.insert n' c s ->
                if Map.size s' >= min' then
                    pure s'
                else
                    loop min' s'

-- | Select a node from the passive view at random.
--
-- If the passive view is empty, 'Nothing' is returned, otherwise 'Just' the
-- random node.
randomPassiveNode :: HyParView n (Maybe n)
randomPassiveNode = do
    Env { envPRNG, envPassive } <- ask
    liftIO $ do
        pasv <- readTVarIO envPassive
        prng <- atomicModifyIORef' envPRNG split
        pure . fst $ randomFromSet pasv prng

-- | Select a node @n'@ from the passive view at random, such that @n' /= n@
randomPassiveNodeNot :: (Eq n, Hashable n) => n -> HyParView n (Maybe n)
randomPassiveNodeNot n = do
    Env { envPRNG, envPassive } <- ask
    liftIO $ do
        pasv <- readTVarIO envPassive
        prng <- atomicModifyIORef' envPRNG split
        pure . fst $ randomFromSet (Set.delete n pasv) prng

-- | Select 'num' nodes from the passive view at random.
--
-- If the passive view is empty, the empty set is returned. 'num' is adjusted to
-- be:
--
-- > min (size passive) (min cfgMaxPassive num)
randomPassiveNodes :: (Eq n, Hashable n) => Int -> HyParView n (HashSet n)
randomPassiveNodes num = do
    Env { envConfig, envPRNG, envPassive } <- ask
    prng <- liftIO $ atomicModifyIORef' envPRNG split
    liftIO . atomically $ do
        pasv <- readTVar envPassive
        let min' = min (Set.size pasv)
                 . min num
                 . fromIntegral . cfgMaxPassive
                 $ envConfig
        loop min' pasv prng Set.empty
  where
    loop min' pasv prng !s =
        case randomFromSet pasv prng of
            (Nothing, _)     -> pure $! s
            (Just n,  prng') | s' <- Set.insert n s ->
                if Set.size s' >= min' then
                    pure $! s'
                else
                    loop min' pasv prng' s'

data SelfConnection = SelfConnection deriving Show
instance Exception SelfConnection

-- | Add a peer to the active view, removing a random other node from the active
-- view if it is full.
--
-- If the peer is in the passive view, it will get removed from there.
--
-- Before the peer is added to the active view, a connection is attempted to be
-- established via 'connectionOpen'. This may fail throwing an arbitrary
-- exception, in which case the peer is /not/ added to the active view.
addToActive
    :: (Eq n, Hashable n, HasPeer n)
    => n
    -> HyParView n (Either SomeException (Connection n))
addToActive n = ask >>= go
  where
    go Env { envSelf }
      | envSelf == n = pure . Left $ toException SelfConnection
      | otherwise    = do
        conn <- connectionOpen (view peerAddr n) (Just (view peerNodeId n))
        case conn of
            Right c -> first toException <$> addConnectedToActive c
            e       -> pure e

addConnectedToActive
    :: (Eq n, Hashable n)
    => Connection n
    -> HyParView n (Either SelfConnection (Connection n))
addConnectedToActive c = do
    env@Env { envSelf, envPRNG, envActive, envPassive } <- ask
    if | connPeer c == envSelf -> Left SelfConnection <$ liftIO (connClose c)
       | otherwise             -> do
        removed <- liftIO $ do
            gen <- atomicModifyIORef' envPRNG split
            atomically $ do
                (removed,_) <- evictActive env gen
                modifyTVar' envActive  $ Map.insert (connPeer c) c
                modifyTVar' envPassive $ Set.delete (connPeer c)
                pure removed
        neighborUp $ connPeer c
        for_ removed $ \(rn, rconn) -> do
            liftIO $ connClose rconn
            neighborDown rn
        pure $ Right c

-- | Add a peer to the passive view, removing a random other node from the
-- passive view if it is full.
addToPassive :: (Eq n, Hashable n) => n -> HyParView n ()
addToPassive n = do
    hdl@Env { envPRNG } <- ask
    liftIO $ do
        gen <- atomicModifyIORef' envPRNG split
        atomically . void $ addToPassive' hdl gen n

-- | Add a set of peers to the passive view.
--
-- This implements an optimisation: by first removing the given peers from the
-- passive view, we avoid having the repeatedly evict peers when the passive
-- view is at capacity.
addAllToPassive :: (Eq n, Hashable n) => HashSet n -> HyParView n ()
addAllToPassive ns = do
    hdl@Env { envSelf = self, envPRNG, envActive, envPassive } <- ask
    liftIO $ do
        gen <- atomicModifyIORef' envPRNG split
        atomically $ do
            actv <- keysSet <$> readTVar envActive
            let ns' = Set.difference (Set.delete self ns) actv
            modifyTVar' envPassive (`Set.difference` ns')
            void $ foldlM (addToPassive' hdl) gen ns'

removeFromActive :: (Eq n, Hashable n) => n -> HyParView n (Maybe (Connection n))
removeFromActive n = do
    prev <- ask >>= liftIO . atomically . flip removeFromActive' n
    for_ prev . const $ neighborDown n
    pure prev

removeFromPassive :: (Eq n, Hashable n) => n -> HyParView n ()
removeFromPassive n = ask >>= liftIO . atomically . flip removeFromPassive' n

-- | Attempt to promote a random passive node to the active view.
--
-- This should be called periodically at an interval smaller than the rate of
-- new nodes joining (which in turn should be rate-limited).
promoteRandom :: (Eq n, Hashable n, HasPeer n) => HyParView n ()
promoteRandom = randomPassiveNode >>= maybe (pure ()) promote
  where
    promote n = do
        x <- addToActive n
        case x of
            Left  _ -> do
                -- TODO(kim): logging?
                removeFromPassive n
                promoteRandom
            Right c -> do
                prio <- neighborPriority
                sendTo c n $ Neighbor prio

--------------------------------------------------------------------------------

numActive :: HyParView n Int
numActive = asks envActive >>= fmap Map.size . liftIO . readTVarIO

mkRPC :: n -> Message n -> HyParView n (RPC n)
mkRPC to payload = do
    s <- asks envSelf
    pure RPC
        { rpcSender    = s
        , rpcRecipient = to
        , rpcPayload   = payload
        }

sendTo
    :: (Eq n, Hashable n, HasPeer n)
    => Connection n
    -> n
    -> Message n
    -> HyParView n ()
sendTo Connection { connSend } to msg = do
    rpc <- mkRPC to msg
    res <- liftIO . tryAny $ connSend rpc
    case res of
        Left  _  -> eject to
        Right () -> pure ()

neighborPriority :: HyParView n Priority
neighborPriority = do
    actv <- asks envActive
    bool Low High . Map.null <$> liftIO (readTVarIO actv)

--------------------------------------------------------------------------------

isActiveAtCapacity :: Env n -> STM Bool
isActiveAtCapacity Env { envConfig = Config { cfgMaxActive }, envActive } = do
    actv <- readTVar envActive
    pure $ Map.size actv >= maxActv
  where
    maxActv = fromIntegral cfgMaxActive

isPassiveAtCapacity :: Env n -> STM Bool
isPassiveAtCapacity Env { envConfig = Config { cfgMaxPassive }, envPassive } = do
    pasv <- readTVar envPassive
    pure $ Set.size pasv >= maxPasv
  where
    maxPasv = fromIntegral cfgMaxPassive

evictActive
    :: (Eq n, Hashable n)
    => Env n
    -> SMGen
    -> STM (Maybe (n, Connection n), SMGen)
evictActive hdl@Env { envActive } gen = do
    full <- isActiveAtCapacity hdl
    if full then do
        m <- readTVar envActive
        let (key, gen') = randomFromSet (keysSet m) gen
        case key of
            Nothing -> pure (Nothing, gen')
            Just  k ->
                case Map.lookup k m of
                    Nothing -> pure (Nothing, gen')
                    Just  v -> do
                        modifyTVar' envActive $ Map.delete k
                        pure (Just (k, v), gen')
    else
        pure (Nothing, gen)

evictPassive :: (Eq n, Hashable n) => Env n -> SMGen -> STM (Maybe n, SMGen)
evictPassive hdl@Env { envPassive } gen = do
    full <- isPassiveAtCapacity hdl
    if full then do
        s <- readTVar envPassive
        let rnd = randomFromSet s gen
        traverse_ (modifyTVar' envPassive . Set.delete) $ fst rnd
        pure rnd
    else
        pure (Nothing, gen)

addToPassive' :: (Eq n, Hashable n) => Env n -> SMGen -> n -> STM SMGen
addToPassive' hdl@Env { envSelf = self, envActive, envPassive } gen n = do
    actv <- readTVar envActive
    if n /= self && not (Map.member n actv) then do
        (_,gen') <- evictPassive hdl gen
        modifyTVar' envPassive $ Set.insert n
        pure gen'
    else
        pure gen

removeFromActive'
    :: (Eq n, Hashable n)
    => Env n
    -> n
    -> STM (Maybe (Connection n))
removeFromActive' Env { envActive } n = do
    actv <- readTVar envActive
    for (Map.lookup n actv) $ \conn -> do
        modifyTVar' envActive $ Map.delete n
        pure conn

removeFromPassive' :: (Eq n, Hashable n) => Env n -> n -> STM ()
removeFromPassive' Env { envPassive } n = modifyTVar' envPassive $ Set.delete n

--------------------------------------------------------------------------------

randomFromSet :: HashSet a -> SMGen -> (Maybe a, SMGen)
randomFromSet s gen | Set.null s = (Nothing, gen)
                    | otherwise  =
    let (i, gen') = randomR (0, Set.size s - 1) gen
     in (listToMaybe . drop i $ Set.toList s, gen')

keysSet :: (Eq k, Hashable k) => HashMap k v -> HashSet k
keysSet = Set.fromList . Map.keys
