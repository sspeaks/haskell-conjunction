{-# LANGUAGE OverloadedStrings #-}

-- | HTTP routing for @conjunction-api@.
--
-- @\/api\/*@ paths are handled by Scotty; everything else is served from the
-- built frontend directory. A CORS layer permits the configured dev-server
-- origin so the Vite dev server can call the API cross-origin.
module Api.Routes
  ( buildApp
  ) where

import Api.Config (Config (..))
import Api.Database (getConjunction, listConjunctions, listRuns, listSatellites)
import Control.Concurrent.MVar (MVar, withMVar)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (object, (.=))
import qualified Data.ByteString.Char8 as BS8
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Time (Day, defaultTimeLocale, parseTimeM)
import Database.PostgreSQL.Simple (Connection)
import Network.HTTP.Types (status200, status404)
import Network.Wai (Application, pathInfo, responseFile)
import Network.Wai.Application.Static (defaultWebAppSettings, staticApp)
import Network.Wai.Middleware.Cors
  ( CorsResourcePolicy (..)
  , cors
  , simpleCorsResourcePolicy
  )
import Network.Wai.Middleware.Gzip (defaultGzipSettings, gzip)
import System.FilePath ((</>))
import WaiAppStatic.Types (StaticSettings (..), unsafeToPiece)
import Web.Scotty
  ( ActionM
  , ScottyM
  , get
  , json
  , pathParam
  , queryParamMaybe
  , scottyApp
  , status
  )

-- | Build the complete WAI application: API routes, CORS, and static files.
-- Non-@\/api@ paths are served from the built frontend directory, with
-- @index.html@ as the index document and a single-page-app fallback so client
-- routes resolve to @index.html@.
buildApp :: Config -> MVar Connection -> IO Application
buildApp cfg connVar = do
  apiApp <- scottyApp (routes connVar)
  let dir = cfgStaticDir cfg
      staticSettings =
        (defaultWebAppSettings dir)
          { ssIndices = [unsafeToPiece "index.html"]
          , ss404Handler = Just (indexFallback dir)
          }
      combined req respond =
        case pathInfo req of
          ("api" : _) -> apiApp req respond
          _ -> staticApp staticSettings req respond
  pure (gzip defaultGzipSettings (corsMiddleware cfg combined))

-- | Serve @index.html@ for any unmatched, non-asset path (SPA fallback).
indexFallback :: FilePath -> Application
indexFallback dir _req respond =
  respond $
    responseFile
      status200
      [("Content-Type", "text/html; charset=utf-8")]
      (dir </> "index.html")
      Nothing

-- | Allow the configured dev-server origin to call the API.
corsMiddleware :: Config -> Application -> Application
corsMiddleware cfg = cors (const (Just policy))
  where
    policy =
      simpleCorsResourcePolicy
        { corsOrigins = Just ([BS8.pack (cfgAllowedOrigin cfg)], False)
        , corsMethods = ["GET", "OPTIONS"]
        , corsRequestHeaders = ["Content-Type", "Accept"]
        }

routes :: MVar Connection -> ScottyM ()
routes connVar = do
  get "/api/health" $
    json (object ["status" .= ("ok" :: T.Text)])

  get "/api/satellites" $ do
    rows <- liftIO (withMVar connVar listSatellites)
    json rows

  get "/api/conjunctions" $ do
    limM <- queryParamMaybe "limit" :: ActionM (Maybe Int)
    dateM <- queryParamMaybe "date" :: ActionM (Maybe T.Text)
    let lim = min (fromMaybe 200 limM) 5000
        day = dateM >>= parseDay
    rows <- liftIO (withMVar connVar (\c -> listConjunctions c day lim))
    json rows

  get "/api/conjunctions/:id" $ do
    cid <- pathParam "id" :: ActionM Int64
    rowM <- liftIO (withMVar connVar (\c -> getConjunction c cid))
    case rowM of
      Just row -> json row
      Nothing -> do
        status status404
        json (object ["error" .= ("conjunction not found" :: T.Text)])

  get "/api/runs" $ do
    limM <- queryParamMaybe "limit" :: ActionM (Maybe Int)
    let lim = min (fromMaybe 100 limM) 1000
    rows <- liftIO (withMVar connVar (\c -> listRuns c lim))
    json rows

-- | Parse a @YYYY-MM-DD@ query parameter into a 'Day'.
parseDay :: T.Text -> Maybe Day
parseDay = parseTimeM True defaultTimeLocale "%Y-%m-%d" . T.unpack
