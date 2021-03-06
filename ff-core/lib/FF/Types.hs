{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}

module FF.Types where

import           CRDT.Cv.Max (Max)
import qualified CRDT.Cv.Max as Max
import           CRDT.Cv.RGA (RgaString)
import qualified CRDT.Cv.RGA as RGA
import           CRDT.LWW (LWW)
import qualified CRDT.LWW as LWW
import           Data.Aeson (camelTo2)
import           Data.Aeson.TH (defaultOptions, deriveJSON, fieldLabelModifier,
                                omitNothingFields)
import           Data.List (genericLength)
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Semigroup (Semigroup, (<>))
import           Data.Semigroup.Generic (gmappend)
import           Data.Semilattice (Semilattice)
import           Data.Text (Text)
import qualified Data.Text as Text
import           Data.Time (Day, diffDays)
import           GHC.Generics (Generic)
import           Numeric.Natural (Natural)

import           FF.CrdtAesonInstances ()
import           FF.Storage (Collection, DocId, collectionName)

data Status = Active | Archived | Deleted
    deriving (Bounded, Enum, Eq, Show)

deriveJSON defaultOptions ''Status

data Tracked = Tracked
    { trackedProvider   :: Text
    , trackedSource     :: Text
    , trackedExternalId :: Text
    , trackedUrl        :: Text
    }
    deriving (Eq, Show, Ord)

deriveJSON defaultOptions{fieldLabelModifier = camelTo2 '_' . drop 7} ''Tracked

data Note = Note
    { noteStatus  :: LWW Status
    , noteText    :: RgaString
    , noteStart   :: LWW Day
    , noteEnd     :: LWW (Maybe Day)
    , noteTracked :: Maybe (Max Tracked)
    }
    deriving (Eq, Generic, Show)

type NoteId = DocId Note

instance Semigroup Note where
    (<>) = gmappend

instance Semilattice Note

deriveJSON
    defaultOptions
        {fieldLabelModifier = camelTo2 '_' . drop 4, omitNothingFields = True}
    ''Note

instance Collection Note where
    collectionName = "note"

data NoteView = NoteView
    { nid     :: Maybe NoteId
    , status  :: Status
    , text    :: Text
    , start   :: Day
    , end     :: Maybe Day
    , tracked :: Maybe Tracked
    }
    deriving (Eq, Show)

data Sample = Sample
    { notes :: [NoteView]
    , total :: Natural
    }
    deriving (Eq, Show)

emptySample :: Sample
emptySample = Sample {notes = [], total = 0}

-- | Number of notes omitted from the sample.
omitted :: Sample -> Natural
omitted Sample { notes, total } = total - genericLength notes

-- | Sub-status of an 'Active' task from the perspective of the user.
data TaskMode
    = Overdue Natural   -- ^ end in past, with days
    | EndToday          -- ^ end today
    | EndSoon Natural   -- ^ started, end in future, with days
    | Actual            -- ^ started, no end
    | Starting Natural  -- ^ starting in future, with days
    deriving (Eq, Show)

taskModeOrder :: TaskMode -> Int
taskModeOrder = \case
    Overdue _  -> 0
    EndToday   -> 1
    EndSoon _  -> 2
    Actual     -> 3
    Starting _ -> 4

instance Ord TaskMode where
    Overdue  n <= Overdue  m = n >= m
    EndSoon  n <= EndSoon  m = n <= m
    Starting n <= Starting m = n <= m
    m1         <= m2         = taskModeOrder m1 <= taskModeOrder m2

taskMode :: Day -> NoteView -> TaskMode
taskMode today NoteView{start, end} = case end of
    Nothing
        | start <= today -> Actual
        | otherwise      -> starting start today
    Just e -> case compare e today of
        LT -> overdue today e
        EQ -> EndToday
        GT  | start <= today -> endSoon  e today
            | otherwise      -> starting start today
  where
    overdue  = helper Overdue
    endSoon  = helper EndSoon
    starting = helper Starting
    helper m x y = m . fromIntegral $ diffDays x y

type ModeMap = Map TaskMode

singletonTaskModeMap :: Day -> NoteView -> ModeMap [NoteView]
singletonTaskModeMap today note = Map.singleton (taskMode today note) [note]

noteView :: NoteId -> Note -> NoteView
noteView nid Note {..} = NoteView
    { nid     = Just nid
    , status  = LWW.query noteStatus
    , text    = Text.pack $ RGA.toString noteText
    , start   = LWW.query noteStart
    , end     = LWW.query noteEnd
    , tracked = Max.query <$> noteTracked
    }

type Limit = Natural
