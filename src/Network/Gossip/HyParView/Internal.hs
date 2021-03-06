{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- |
-- Copyright   : 2018 Monadic GmbH
-- License     : BSD3
-- Maintainer  : kim@monadic.xyz, team@monadic.xyz
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--
module Network.Gossip.HyParView.Internal
    ( TimeToLive
    , decr
    , isExpired
    ) where

import           Codec.Serialise (Serialise)
import           Data.Word (Word8)
import           GHC.Generics (Generic)

-- | The time-to-live of a random walk.
--
-- \"Forward Join\" and \"Shuffle\" RPCs are propagated using a random walk,
-- where each hop decrements the 'TimeToLive' until it 'isExpired', at which
-- point the respective operation is applied to the current node's state. We
-- retain the terminology, even though no time component is involved.
newtype TimeToLive = TimeToLive { fromTimeToLive :: Word8 }
    deriving (Eq, Num, Bounded, Ord, Generic)

instance Serialise TimeToLive

decr :: TimeToLive -> TimeToLive
decr ttl | ttl > minBound = TimeToLive . pred . fromTimeToLive $ ttl
         | otherwise      = ttl

isExpired :: TimeToLive -> Bool
isExpired (TimeToLive t) = t == 0
