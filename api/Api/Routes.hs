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
-- Non-@\/api@ paths are served from the built frontend directory. The hashed
-- @\/assets\/*@ files keep an immutable long-lived cache, while @index.html@
-- (the root and the single-page-app fallback) is served @no-cache@ so a new
-- deploy's asset hashes are always picked up.
buildApp :: Config -> MVar Connection -> IO Application
buildApp cfg connVar = do
  apiApp <- scottyApp (routes connVar)
  let dir = cfgStaticDir cfg
      staticSettings =
        (defaultWebAppSettings dir)
          { ssIndices = [unsafeToPiece "index.html"]
          , ss404Handler = Just (serveIndex dir)
          }
      combined req respond =
        case pathInfo req of
          ("api" : _) -> apiApp req respond
          -- Serve index.html for the root ourselves so it is not cached
          -- with the immutable header staticApp applies to hashed assets.
          [] -> serveIndex dir req respond
          ["index.html"] -> serveIndex dir req respond
          _ -> staticApp staticSettings req respond
  pure (gzip defaultGzipSettings (corsMiddleware combined))

-- | Serve @index.html@ with a @no-cache@ header. Used for the root and as the
-- single-page-app fallback for unmatched client routes, so the browser always
-- revalidates the entry document and never pins a stale asset reference.
serveIndex :: FilePath -> Application
serveIndex dir _req respond =
  respond $
    responseFile
      status200
      [ ("Content-Type", "text/html; charset=utf-8")
      , ("Cache-Control", "no-cache")
      ]
      (dir </> "index.html")
      Nothing

-- | CORS for a read-only, unauthenticated public API: allow any origin.
--
-- This also matters for serving the built frontend: Vite tags the bundled
-- @\<script\>@ and @\<link\>@ with @crossorigin@, so browsers fetch those
-- assets in CORS mode with an @Origin@ header. A policy restricted to a single
-- origin would reject the app's own origin with @400@, so we allow all origins
-- (which emits @Access-Control-Allow-Origin: *@). The API exposes no
-- credentials or secrets, so this is safe.
corsMiddleware :: Application -> Application
corsMiddleware = cors (const (Just policy))
  where
    policy =
      simpleCorsResourcePolicy
        { corsMethods = ["GET", "OPTIONS"]
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
