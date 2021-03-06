{-# LANGUAGE CPP          #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Copyright   : 2018 Monadic GmbH
-- License     : BSD3
-- Maintainer  : kim@monadic.xyz, team@monadic.xyz
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--
module Network.Gossip.IO.Peer
    ( Peer (..)

    , knownPeer
    , resolve
    )
where

import qualified Network.Gossip.HyParView as H

import           Codec.Serialise (Serialise(..))
import qualified Codec.Serialise.Decoding as CBOR
import qualified Codec.Serialise.Encoding as CBOR
import           Control.Applicative (liftA2)
import           Control.Monad.Fail (fail)
import           Data.Hashable (Hashable(..), hashUsing)
import           Data.Word (Word8)
#if !MIN_VERSION_network(3,0,0)
import           GHC.Stack (HasCallStack)
#endif
import           Lens.Micro (lens)
import           Network.Socket
import           Network.Socket.Serialise (decodeSockAddr, encodeSockAddr)
import           Prelude hiding (fail)

data Peer n = Peer
    { peerNodeId :: n
    , peerAddr   :: SockAddr
    } deriving (Eq, Show)

instance H.HasPeerNodeId (Peer n) where
    type NodeId (Peer n) = n

    peerNodeId = lens peerNodeId (\s a -> s { peerNodeId = a })
    {-# INLINE peerNodeId #-}

instance H.HasPeerAddr (Peer n) where
    type Addr (Peer n) = SockAddr

    peerAddr = lens peerAddr (\s a -> s { peerAddr = a })
    {-# INLINE peerAddr #-}

instance Serialise n => Serialise (Peer n) where
    encode (Peer nid addr) =
           CBOR.encodeListLen 3
        <> CBOR.encodeWord 0
        <> encode nid
        <> encodeSockAddr addr

    decode = do
        pre <- liftA2 (,) CBOR.decodeListLen CBOR.decodeWord
        case pre of
            (3, 0) -> liftA2 Peer decode decodeSockAddr
            _      -> fail "CBOR Peer: invalid tag"

instance Hashable n => Hashable (Peer n) where
    hashWithSalt salt (Peer nid addr) =
        (salt `hashWithSalt` nid) `hashAddr` addr
      where
        hashAddr s (SockAddrInet portNum hostAddr) =
            (s `hashWithSalt` (0 :: Word8))
               `hashPortNum`  portNum
               `hashWithSalt` hostAddr

        hashAddr s (SockAddrInet6 portNum flow hostAddr scope) =
            (s `hashWithSalt` (1 :: Word8))
               `hashPortNum`  portNum
               `hashWithSalt` flow
               `hashWithSalt` hostAddr
               `hashWithSalt` scope

        hashAddr s (SockAddrUnix path) =
            s `hashWithSalt` (2 :: Word8) `hashWithSalt` path

#if !MIN_VERSION_network(3,0,0)
        -- hashAddr s (SockAddrCan x) = canNotSupported
        hashAddr _ _ = canNotSupported
#endif

        hashPortNum = hashUsing fromEnum

knownPeer :: n -> HostName -> PortNumber -> IO (Peer n)
knownPeer nid host port = Peer nid <$> resolve host port

resolve :: HostName -> PortNumber -> IO SockAddr
resolve host port = do
    let hints = defaultHints
                  { addrFlags      = [AI_ALL, AI_NUMERICSERV]
                  , addrSocketType = Stream
                  }
    addr:_ <- getAddrInfo (Just hints) (Just host) (Just (show port))
    pure $ addrAddress addr

--------------------------------------------------------------------------------

#if !MIN_VERSION_network(3,0,0)
canNotSupported :: HasCallStack => a
canNotSupported = error "CAN addresses not supported"
#endif
