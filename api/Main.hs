{-# LANGUAGE OverloadedStrings #-}

-- | Entry point for the @conjunction-api@ HTTP server.
module Main (main) where

import Api.Config (Config (..), parseConfig)
import Api.Database (openConnection)
import Api.Routes (buildApp)
import Control.Concurrent.MVar (newMVar)
import Network.Wai.Handler.Warp
  ( defaultSettings
  , runSettings
  , setMaxTotalHeaderLength
  , setPort
  )
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  cfg <- parseConfig
  conn <- openConnection cfg
  connVar <- newMVar conn
  app <- buildApp cfg connVar
  -- Browsers attach the full localhost cookie jar (shared across every
  -- localhost port) plus Referer/Sec-Fetch headers, which can exceed Warp's
  -- default ~50 KB header cap and make it reject asset requests with 400.
  -- Raise the cap generously so a fat localhost cookie jar can't break the app.
  let settings =
        setPort (cfgPort cfg)
          . setMaxTotalHeaderLength (1024 * 1024)
          $ defaultSettings
  hPutStrLn stderr ("conjunction-api listening on http://0.0.0.0:" <> show (cfgPort cfg))
  runSettings settings app
