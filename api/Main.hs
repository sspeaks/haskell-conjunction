{-# LANGUAGE OverloadedStrings #-}

-- | Entry point for the @conjunction-api@ HTTP server.
module Main (main) where

import Api.Config (Config (..), parseConfig)
import Api.Database (openConnection)
import Api.Routes (buildApp)
import Control.Concurrent.MVar (newMVar)
import Network.Wai.Handler.Warp (run)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  cfg <- parseConfig
  conn <- openConnection cfg
  connVar <- newMVar conn
  app <- buildApp cfg connVar
  hPutStrLn stderr ("conjunction-api listening on http://0.0.0.0:" <> show (cfgPort cfg))
  run (cfgPort cfg) app
