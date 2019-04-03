{-|
  Copyright  :  (C) 2012-2016, University of Twente,
                    2017     , Myrtle Software Ltd
  License    :  BSD2 (see the file LICENSE)
  Maintainer :  Christiaan Baaij <christiaan.baaij@gmail.com>

  Parser definitions for BlackBox templates
-}

{-# LANGUAGE OverloadedStrings #-}

module Clash.Netlist.BlackBox.Parser
  (runParse)
where

import           Control.Applicative          ((<|>))
import           Data.Text.Lazy               (Text, pack, unpack)
import qualified Data.Text.Lazy               as Text
import           Text.Parser.Combinators
import           Text.Trifecta                hiding (Err)
import           Text.Trifecta.Delta

import           Clash.Netlist.BlackBox.Types

-- | Parse a text as a BlackBoxTemplate, returns a list of errors in case
-- parsing fails
-- runParse :: Text -> (BlackBoxTemplate, [Error LineColPos])
-- runParse = PCC.parse ((,) <$> pBlackBoxD <*> pEnd)
--          . createStr (LineColPos 0 0 0)
runParse :: Text -> Result BlackBoxTemplate
runParse = parseString pBlackBoxD (Directed "" 0 0 0 0) . unpack

-- | Parse a BlackBoxTemplate (Declarations and Expressions)
pBlackBoxD :: Parser BlackBoxTemplate
pBlackBoxD = some pElement

-- | Parse a single Template Element
pElement :: Parser Element
pElement  =  pTagD
         <|> Text <$> pText
         <|> Text <$> (pack <$> string "~ ")

-- | Parse the Text part of a Template
pText :: Parser Text
pText = pack <$> some (satisfyRange '\000' '\125')

-- | Parse a Declaration or Expression element
pTagD :: Parser Element
pTagD =  IF <$> (symbol "~IF" *> pTagE)
            <*> (spaces *> (string "~THEN" *> pBlackBoxD))
            <*> (string "~ELSE" *> pBlackBoxD <* string "~FI")
     <|> Component <$> pDecl
     <|> pTagE

-- | Parse a Declaration
pDecl :: Parser Decl
pDecl = Decl <$> (symbol "~INST" *> natural') <*>
        ((:) <$> pOutput <*> many pInput) <* string "~INST"

-- | Parse the output tag of Declaration
pOutput :: Parser (BlackBoxTemplate,BlackBoxTemplate)
pOutput = symbol "~OUTPUT" *> symbol "<=" *> ((,) <$> (pBlackBoxE <* symbol "~") <*> pBlackBoxE) <* symbol "~"

-- | Parse the input tag of Declaration
pInput :: Parser (BlackBoxTemplate,BlackBoxTemplate)
pInput = symbol "~INPUT" *> symbol "<=" *> ((,) <$> (pBlackBoxE <* symbol "~") <*> pBlackBoxE) <* symbol "~"

-- | Parse an Expression element
pTagE :: Parser Element
pTagE =  Result True       <$  string "~ERESULT"
     <|> Result False      <$  string "~RESULT"
     <|> ArgGen            <$> (string "~ARGN" *> brackets' natural') <*> brackets' natural'
     <|> Arg True          <$> (string "~EARG" *> brackets' natural')
     <|> Arg False         <$> (string "~ARG" *> brackets' natural')
     <|> Const             <$> (string "~CONST" *> brackets' natural')
     <|> Lit               <$> (string "~LIT" *> brackets' natural')
     <|> Name              <$> (string "~NAME" *> brackets' natural')
     <|> Var               <$> try (string "~VAR" *> brackets' pSigD) <*> brackets' natural'
     <|> (Sym Text.empty)  <$> (string "~SYM" *> brackets' natural')
     <|> Typ Nothing       <$  string "~TYPO"
     <|> (Typ . Just)      <$> try (string "~TYP" *> brackets' natural')
     <|> TypM Nothing      <$  string "~TYPMO"
     <|> (TypM . Just)     <$> (string "~TYPM" *> brackets' natural')
     <|> Err Nothing       <$  string "~ERRORO"
     <|> (Err . Just)      <$> (string "~ERROR" *> brackets' natural')
     <|> TypElem           <$> (string "~TYPEL" *> brackets' pTagE)
     <|> IndexType         <$> (string "~INDEXTYPE" *> brackets' pTagE)
     <|> CompName          <$  string "~COMPNAME"
     <|> IncludeName       <$> (string "~INCLUDENAME" *> brackets' natural')
     <|> Size              <$> (string "~SIZE" *> brackets' pTagE)
     <|> Length            <$> (string "~LENGTH" *> brackets' pTagE)
     <|> Depth             <$> (string "~DEPTH" *> brackets' pTagE)
     <|> FilePath          <$> (string "~FILE" *> brackets' pTagE)
     <|> Gen               <$> (True <$ string "~GENERATE")
     <|> Gen               <$> (False <$ string "~ENDGENERATE")
     <|> (`SigD` Nothing)  <$> (string "~SIGDO" *> brackets' pSigD)
     <|> SigD              <$> (string "~SIGD" *> brackets' pSigD) <*> (Just <$> (brackets' natural'))
     <|> IW64              <$  string "~IW64"
     <|> CmpLE             <$> try (string "~CMPLE" *> brackets' pTagE) <*> brackets' pTagE
     <|> (HdlSyn Vivado)   <$  string "~VIVADO"
     <|> (HdlSyn Other)    <$  string "~OTHERSYN"
     <|> (BV True)         <$> (string "~TOBV" *> brackets' pSigD) <*> brackets' pTagE
     <|> (BV False)        <$> (string "~FROMBV" *> brackets' pSigD) <*> brackets' pTagE
     <|> Sel               <$> (string "~SEL" *> brackets' pTagE) <*> brackets' natural'
     <|> IsLit             <$> (string "~ISLIT" *> brackets' natural')
     <|> IsVar             <$> (string "~ISVAR" *> brackets' natural')
     <|> IsGated           <$> (string "~ISGATED" *> brackets' natural')
     <|> IsSync            <$> (string "~ISSYNC" *> brackets' natural')
     <|> StrCmp            <$> (string "~STRCMP" *> brackets' pSigD) <*> brackets' natural'
     <|> OutputWireReg     <$> (string "~OUTPUTWIREREG" *> brackets' natural')
     <|> GenSym            <$> (string "~GENSYM" *> brackets' pSigD) <*> brackets' natural'
     <|> Template          <$> (string "~TEMPLATE" *> brackets' pSigD) <*> brackets' pSigD
     <|> Repeat            <$> (string "~REPEAT" *> brackets' pSigD) <*> brackets' pSigD
     <|> DevNull           <$> (string "~DEVNULL" *> brackets' pSigD)
     <|> And               <$> (string "~AND" *> brackets' (commaSep pTagE))
     <|> Vars              <$> (string "~VARS" *> brackets' natural')

natural' :: TokenParsing m => m Int
natural' = fmap fromInteger natural

-- | Parse a bracketed text
brackets' :: Parser a -> Parser a
brackets' p = char '[' *> p <* char ']'

-- | Parse the expression part of Blackbox Templates
pBlackBoxE :: Parser BlackBoxTemplate
pBlackBoxE = some pElemE

-- | Parse an Expression or Text
pElemE :: Parser Element
pElemE = pTagE
      <|> Text <$> pText

-- | Parse SigD
pSigD :: Parser [Element]
pSigD = some (pTagE <|> (Text (pack "[") <$ (pack <$> string "[\\"))
                    <|> (Text (pack "]") <$ (pack <$> string "\\]"))
                    <|> (Text <$> (pack <$> some (satisfyRange '\000' '\90')))
                    <|> (Text <$> (pack <$> some (satisfyRange '\94' '\125'))))
