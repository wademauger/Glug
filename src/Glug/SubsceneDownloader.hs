{-# LANGUAGE OverloadedStrings #-}

module Glug.SubsceneDownloader (
  candidateTitles
, getSubtitles
)
where


import qualified Data.ByteString.Lazy as BSL
import qualified Data.Text.Lazy as T
import qualified Data.Text.Lazy.Encoding as T
import qualified Text.EditDistance as ED
import qualified Text.HTML.TagSoup as TS

import Control.Monad.Except
import Data.Char (isSpace)
import Data.List (group, sort, sortOn)
import Network.HTTP.Base (urlEncode)
import Text.Read (readEither)

import Glug.Monad (execMonadGlugIO, realTlsGetM)
import Glug.SrtExtract (parseSrtFromZip)
import Glug.Types (MovieSubtitles (..))


searchurl :: String
subscenebase :: String
searchurl = "https://subscene.com/subtitles/title?q="
subscenebase = "https://subscene.com"


-- | Gets the subtitles from a movie
getSubtitles :: String -- ^ The path to the subtitle listing on subscene
                -> IO (Either String MovieSubtitles) -- ^ Either an error
                                                     -- message or movie subtitles
getSubtitles s = runExceptT $ do
    soup <- getSoup $ subscenebase ++ s
    cands <- liftEither $ getSubLinks soup
    id_ <- liftEither $ getImdbUrl soup >>= extractId >>= pad >>= Right . T.append "tt"
    subs <- getSub cands
    return $ MovieSubtitles { imdbid = id_, subtitles = subs }
  where getSub [] = throwError "No subtitles found"
        getSub (x:xs) = (subAt . T.unpack $ x) ||> getSub xs
        subAt subpath = do
            soup <- getSoup $ subscenebase ++ subpath
            downLink <- liftEither $ getDownloadLink soup
            subs <- makeGet (subscenebase ++ (T.unpack downLink))
            parseSrtFromZip subs
        extractId t = fromMaybe (T.stripPrefix "http://www.imdb.com/title/tt" t) "did not find valid imdb id"
        pad = Right . T.justifyRight 7 '0'


-- | Gets candidate titles from a movie after searching by title
candidateTitles :: String
                   -- ^ The movie title being searched
                   -> IO (Either String [(T.Text, T.Text, Integer)])
                   -- ^ Either an error message or a list of
                   --   (href, title, no. of subs)
candidateTitles s = runExceptT $ do
    soup <- getSoup $ searchurl ++ (quote_plus s)
    titles <- liftEither $ getTitles soup
    return . sortOn (\(_, t, _) -> editDist (T.unpack t)) . dedup $ titles
  where dedup = map (head) . group . sort
        editDist = ED.levenshteinDistance ED.defaultEditCosts s


getSoup :: String -> ExceptT String IO ([TS.Tag T.Text])
getSoup s = do
    bs <- makeGet s
    txt <- ExceptT . return . eitherShow . T.decodeUtf8' $ bs
    return . TS.parseTags $ txt


makeGet :: String -> ExceptT String IO BSL.ByteString
makeGet url = ExceptT . liftM (fst) . execMonadGlugIO $ realTlsGetM url


-- ----------------------------- Soup Handling ------------------------------ --

getDownloadLink :: [TS.Tag T.Text] -> Either String T.Text
getDownloadLink [] = Left "no download link found"
getDownloadLink ((TS.TagOpen name attrs):xs)
    | name == "a" && ("id", "downloadButton") `elem` attrs
                = eitherAttr attrs "href"
    | otherwise = getDownloadLink xs
getDownloadLink (_:xs) = getDownloadLink xs


getSubLinks :: [TS.Tag T.Text] -> Either String [T.Text]
getSubLinks [] = Right []
getSubLinks ((TS.TagOpen name1 attrs1):
             (TS.TagText _):
             (TS.TagOpen name2 attrs2):
             (TS.TagText engl):
             ts)
    | name1 == "a" && name2 == "span" && (removeSpaces engl) == "English" && attrs2 == [("class", "l r positive-icon")]
                = do
                    hrf <- eitherAttr attrs1 "href"
                    rest <- getSubLinks ts
                    return ((hrf):rest)
    | otherwise = getSubLinks ((TS.TagOpen name2 attrs2):((TS.TagText engl):ts))
  where removeSpaces = T.filter (not . isSpace)
getSubLinks (_:ts) = getSubLinks ts


getTitles :: [TS.Tag T.Text] -> Either String [(T.Text, T.Text, Integer)]
getTitles [] = Right []
getTitles ((TS.TagOpen name attrs): xs)
    | name == "div" && attrs == [("class", "title")] = do
        (href, title, rest) <- findHrefTitle xs
        (i, rest') <- findCount rest
        next <- getTitles rest'
        Right $ (href, title, i) : next
  where findHrefTitle [] = Left "No title found"
        findHrefTitle ((TS.TagOpen name' attrs'):
                       (TS.TagText title): ts)
            | name' == "a" = do
                href <- eitherAttr attrs' "href"
                Right (href, title, ts)
            | otherwise     = findHrefTitle ts
        findHrefTitle (_:ts) = findHrefTitle ts
        findCount [] = Left "No count found"
        findCount ((TS.TagOpen name' attrs'):(TS.TagText txt):ts)
            | name' == "div" && attrs' == [("class", "subtle count")]
                        = readEither txt' >>= \i -> return (i, ts)
            | otherwise = findCount ts
          where txt' = takeWhile (/= ' ') . T.unpack $ txt
        findCount (_:ts) = findCount ts
getTitles (_:xs) = getTitles xs


getImdbUrl :: [TS.Tag T.Text] -> Either String T.Text
getImdbUrl [] = Left "No IMDb Id Found"
getImdbUrl ((TS.TagOpen name attrs): _)
    | name == "a" && ("class", "imdb") `elem` attrs = eitherAttr attrs "href"
getImdbUrl (_:xs) = getImdbUrl xs


-- -------------------------------- Utilities ------------------------------- --

-- \ If first operation errors, uses second operation. Similar to `mplus`
(||>) :: Monad m => ExceptT a m b -> ExceptT a m b -> ExceptT a m b
x ||> y = x `catchError` (\_ -> y)


eitherShow :: Show a => Either a b -> Either String b
eitherShow (Left x) = Left $ show x
eitherShow (Right x) = Right x


eitherAttr :: [(T.Text, T.Text)] -> T.Text
                  -> Either String T.Text
eitherAttr [] s = Left $ "could not find attr " ++ (T.unpack s)
eitherAttr ((k, v):xs) s
    | k == s    = Right v
    | otherwise = eitherAttr xs s


liftEither :: Either a b -> ExceptT a IO b
liftEither = ExceptT . return


fromMaybe :: Maybe b -> String -> Either String b
fromMaybe Nothing s = Left s
fromMaybe (Just x) _ = Right x


quote_plus :: String -> String
quote_plus = replacep20 . urlEncode


replacep20 :: String -> String
replacep20 [] = []
replacep20 (x:[]) = [x]
replacep20 (x:y:[]) = [x, y]
replacep20 (x:y:z:zs)
  | [x, y, z] == "%20" = '+' : (replacep20 zs)
  | otherwise          = x : (replacep20 (y:z:zs))
