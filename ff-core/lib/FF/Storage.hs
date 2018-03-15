{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module FF.Storage where

import           Prelude hiding (readFile)

import           Control.Concurrent.STM (TVar)
import           Control.Monad (when)
import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Control.Monad.Reader (MonadReader, ReaderT, asks, runReaderT)
import           CRDT.Cv (CvRDT)
import           CRDT.LamportClock (Clock, LamportClock,
                                    LamportTime (LamportTime), LocalTime,
                                    Pid (Pid), Process, getTime,
                                    runLamportClock)
import           Data.Aeson (FromJSON, ToJSON, ToJSONKey, eitherDecode, encode)
import qualified Data.ByteString.Lazy as BSL
import           Data.Char (chr, ord)
import           Data.List.NonEmpty (nonEmpty)
import           Data.Semigroup (sconcat)
import           Data.Traversable (for)
import           Numeric (showIntAtBase)
import           System.Directory (createDirectoryIfMissing, doesDirectoryExist,
                                   listDirectory)
import           System.FilePath ((</>))

class (CvRDT doc, FromJSON doc, ToJSON doc) => Collection doc where
    collectionName :: FilePath

newtype DocId doc = DocId FilePath
    deriving (Eq, Ord, ToJSON, ToJSONKey)

instance Show (DocId doc) where
    show (DocId path) = path

-- | Environment is the dataDir
newtype StorageAction a = StorageAction (ReaderT FilePath LamportClock a)
    deriving (Applicative, Clock, Functor, Monad, MonadIO, Process)

type Version = FilePath

-- | Environment is the dataDir
class Clock m => MonadStorage m where
    listDirectoryIfExists
        :: FilePath     -- ^ Path relative to data dir
        -> m [FilePath] -- ^ Paths relative to data dir
    createFile :: Collection doc => DocId doc -> LamportTime -> doc -> m ()
    readFile :: Collection doc => DocId doc -> Version -> m doc

instance MonadStorage StorageAction where
    listDirectoryIfExists relpath = StorageAction $ do
        dir <- asks (</> relpath)
        liftIO $ do
            exists <- doesDirectoryExist dir
            if exists then listDirectory dir else pure []

    createFile docId time doc = StorageAction $ do
        docDir <- askDocDir docId
        let file = docDir </> lamportTimeToFileName time
        liftIO $ do
            createDirectoryIfMissing True docDir
            BSL.writeFile file $ encode doc

    readFile docId version = StorageAction $ do
        docDir <- askDocDir docId
        let file = docDir </> version
        contents <- liftIO $ BSL.readFile file
        pure $
            either (error . ((file ++ ": ") ++)) id $
            eitherDecode contents

data StorageConfig = StorageConfig
    { dataDir :: FilePath
    , clock   :: TVar LocalTime
    }

runStorage :: StorageConfig -> StorageAction a -> IO a
runStorage StorageConfig { dataDir, clock } (StorageAction action) =
    runLamportClock clock $ runReaderT action dataDir

listDocuments
    :: forall doc m . (Collection doc, MonadStorage m) => m [DocId doc]
listDocuments = map DocId <$> listDirectoryIfExists (collectionName @doc)

load
    :: forall doc m
     . (Collection doc, MonadStorage m)
    => DocId doc
    -> m (Maybe doc)
load docId = do
    versions      <- listVersions docId
    versionValues <- for versions $ readFile docId
    pure $ sconcat <$> nonEmpty versionValues

listVersions
    :: forall doc m
     . (Collection doc, MonadStorage m)
    => DocId doc
    -> m [Version]
listVersions (DocId docId) =
    listDirectoryIfExists $ collectionName @doc </> docId

askDocDir
    :: forall doc m
     . (Collection doc, MonadReader FilePath m)
    => DocId doc
    -> m FilePath
askDocDir (DocId docId) = asks (</> collectionName @doc </> docId)

save
    :: forall doc m
     . (Collection doc, MonadStorage m)
    => DocId doc
    -> doc
    -> m ()
save docId doc = do
    time <- getTime
    createFile docId time doc

saveNew :: (Collection doc, MonadStorage m) => doc -> m (DocId doc)
saveNew doc = do
    docId <- DocId . lamportTimeToFileName <$> getTime
    save docId doc
    pure docId

showBase36K :: (Integral a, Show a) => a -> String -> String
showBase36K = showIntAtBase 36 intToDigit36

showBase36 :: (Integral a, Show a) => a -> String
showBase36 a = showBase36K a ""

intToDigit36 :: Int -> Char
intToDigit36 i | (i >= 0) && (i <= 9)   = chr (ord '0' + i)
               | (i >= 10) && (i <= 35) = chr (ord 'a' - 10 + i)
               | otherwise              = error ("not a digit " ++ show i)

lamportTimeToFileName :: LamportTime -> FilePath
lamportTimeToFileName (LamportTime time (Pid pid)) =
    showBase36K time $ '-' : showBase36K pid ""

-- | For user-supplied function input Nothing means non-existent document.
modify
    :: (Collection doc, Eq doc, MonadStorage m)
    => DocId doc
    -> (Maybe doc -> m (a, doc))
    -> m a
modify docId f = do
    mDocOld     <- load docId
    (a, docNew) <- f mDocOld
    when (Just docNew /= mDocOld) $ save docId docNew
    pure a
