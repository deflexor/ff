{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeOperators #-}

module FF.Serve
    ( cmdServe ) where

import           Control.Monad (when)
import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Data.Maybe (isJust, fromJust)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import           Web.Scotty (scotty, get, html)
import           Text.Blaze.Html (stringValue)
import           Text.Blaze.Html.Renderer.Text (renderHtml)
import           Text.Blaze.Html5 (Html, meta, style, a, p, b, h1, h3, section, ul, li, toHtml, (!))
import qualified Text.Blaze.Html5.Attributes as A

import           FF (getUtcToday, getSamples)
import           FF.Storage (runStorage)
import qualified FF.Storage as Storage
import           FF.Config (ConfigUI (..))
import           FF.Types (NoteView(..), ModeMap, Sample (..), TaskMode (..), Tracked(..),  omitted)


serveHttpPort :: Int
serveHttpPort = 8080

cmdServe :: MonadIO m => Storage.Handle -> ConfigUI -> m ()
cmdServe h ui =
    liftIO $ scotty serveHttpPort $ get "/" $ do
        today <- getUtcToday
        nvs <- liftIO $ runStorage h $ getSamples ui Nothing today
        html $ renderHtml $ do
            meta ! A.charset "utf-8"
            style ".info-item * { margin: 2px; }"
            prettyHtmlSamplesBySections nvs

prettyHtmlSamplesBySections :: ModeMap Sample -> Html
prettyHtmlSamplesBySections samples = do
    mconcat [prettyHtmlSample mode sample | (mode, sample) <- Map.assocs samples]
    mconcat [p $ toHtml numOmitted <> " task(s) omitted" | numOmitted > 0]
  where
    numOmitted = sum $ fmap omitted samples

prettyHtmlSample :: TaskMode -> Sample -> Html
prettyHtmlSample mode = \case
    Sample{total = 0} -> mempty
    Sample{notes} ->
        section $ do
            h1 $ toHtml (labels mode)
            ul $ mconcat $ map fmtNote notes
  where
    fmtNote (NoteView nid _ text start _ tracked) =
        li $ do
            h3 $ toHtml text
            when (isJust nid) $ section ! A.class_ "info-item" $ do
                b "id"
                toHtml $ show $ fromJust nid
            section ! A.class_ "info-item" $ do
                b "start"
                toHtml $ show start
            when (isJust tracked) $ do
                section ! A.class_ "info-item" $ do
                    b "tracking"
                    toHtml $ trackedSource $ fromJust tracked
                section ! A.class_ "info-item" $ do
                    let url = trackedUrl $ fromJust tracked
                    b "url"
                    a ! A.href (stringValue $ Text.unpack url) $ toHtml url
    labels = \case
        Overdue n -> case n of
            1 -> "1 day overdue:"
            _ -> show n <> " days overdue:"
        EndToday -> "Due today:"
        EndSoon n -> case n of
            1 -> "Due tomorrow:"
            _ -> "Due in " <> show n <> " days:"
        Actual -> "Actual:"
        Starting n -> case n of
            1 -> "Starting tomorrow:"
            _ -> "Starting in " <> show n <> " days:"

