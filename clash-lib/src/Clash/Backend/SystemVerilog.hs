{-|
  Copyright   :  (C) 2015-2016, University of Twente,
                     2017-2018, Google Inc.
  License     :  BSD2 (see the file LICENSE)
  Maintainer  :  Christiaan Baaij <christiaan.baaij@gmail.com>

  Generate SystemVerilog for assorted Netlist datatypes
-}

{-# LANGUAGE CPP               #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE MultiWayIf        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo       #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE ViewPatterns      #-}

module Clash.Backend.SystemVerilog (SystemVerilogState) where

import qualified Control.Applicative                  as A
import           Control.Lens                         hiding (Indexed)
import           Control.Monad                        (forM,liftM,zipWithM)
import           Control.Monad.State                  (State)
import           Data.Bits                            (Bits, testBit)
import           Data.Graph.Inductive                 (Gr, mkGraph, topsort')
import           Data.HashMap.Lazy                    (HashMap)
import qualified Data.HashMap.Lazy                    as HashMap
import           Data.HashSet                         (HashSet)
import qualified Data.HashSet                         as HashSet
import           Data.List                            (nub, nubBy)
import           Data.Maybe                           (catMaybes,fromMaybe,mapMaybe)
#if !MIN_VERSION_base(4,11,0)
import           Data.Monoid                          hiding (Sum, Product)
#endif
import           Data.Semigroup.Monad
import           Data.Text.Lazy                       (pack,unpack,intercalate)
import qualified Data.Text.Lazy                       as Text
import           Data.Text.Prettyprint.Doc.Extra
#ifdef CABAL
import qualified Data.Version
#endif
import qualified System.FilePath

import           Clash.Annotations.Primitive          (HDL (..))
import           Clash.Annotations.BitRepresentation.Internal
  (ConstrRepr'(..))
import           Clash.Annotations.BitRepresentation.ClashLib
  (bitsToBits)
import           Clash.Annotations.BitRepresentation.Util
  (BitOrigin(Lit, Field), bitOrigins, bitRanges)
import           Clash.Core.Var                       (Attr'(..))
import           Clash.Backend
import           Clash.Backend.Verilog                (bits, bit_char, exprLit, include)
import           Clash.Driver.Types                   (SrcSpan, noSrcSpan)
import           Clash.Netlist.BlackBox.Types         (HdlSyn (..))
import           Clash.Netlist.BlackBox.Util
  (extractLiterals, renderBlackBox, renderFilePath)
import           Clash.Netlist.Id                     (IdType (..), mkBasicId')
import           Clash.Netlist.Types                  hiding (_intWidth, intWidth)
import           Clash.Netlist.Util                   hiding (mkIdentifier, extendIdentifier)
import           Clash.Signal.Internal                (ClockKind (..))
import           Clash.Util
  (curLoc, makeCached, (<:>), first, on, traceIf)

#ifdef CABAL
import qualified Paths_clash_lib
#endif

-- | State for the 'Clash.Backend.SystemVerilog.SystemVerilogM' monad:
data SystemVerilogState =
  SystemVerilogState
    { _tyCache   :: HashSet HWType -- ^ Previously encountered  HWTypes
    , _tySeen    :: [Identifier] -- ^ Product type counter
    , _nameCache :: HashMap HWType Doc -- ^ Cache for previously generated product type names
    , _genDepth  :: Int -- ^ Depth of current generative block
    , _modNm     :: String
    , _idSeen    :: [Identifier]
    , _oports    :: [Identifier]
    , _srcSpan   :: SrcSpan
    , _includes  :: [(String,Doc)]
    , _imports   :: [Text.Text]
    , _dataFiles      :: [(String,FilePath)]
    -- ^ Files to be copied: (filename, old path)
    , _memoryDataFiles:: [(String,String)]
    -- ^ Files to be stored: (filename, contents). These files are generated
    -- during the execution of 'genNetlist'.
    , _intWidth  :: Int -- ^ Int/Word/Integer bit-width
    , _hdlsyn    :: HdlSyn
    }

makeLenses ''SystemVerilogState

squote :: Mon (State SystemVerilogState) Doc
squote = string "'"

primsRoot :: IO FilePath
#ifdef CABAL
primsRoot = Paths_clash_lib.getDataFileName "prims"
#else
primsRoot = return ("clash-lib" System.FilePath.</> "prims")
#endif

instance Backend SystemVerilogState where
  initBackend     = SystemVerilogState HashSet.empty [] HashMap.empty 0 "" [] [] noSrcSpan [] [] [] []
  hdlKind         = const SystemVerilog
  primDirs        = const $ do root <- primsRoot
                               return [ root System.FilePath.</> "common"
                                      , root System.FilePath.</> "commonverilog"
                                      , root System.FilePath.</> "systemverilog"
                                      ]
  extractTypes    = _tyCache
  name            = const "systemverilog"
  extension       = const ".sv"

  genHDL          = genVerilog
  mkTyPackage     = mkTyPackage_
  hdlType _       = verilogType
  hdlTypeErrValue = verilogTypeErrValue
  hdlTypeMark     = verilogTypeMark
  hdlRecSel       = verilogRecSel
  hdlSig t ty     = sigDecl (string t) ty
  genStmt True    = do cnt <- use genDepth
                       genDepth += 1
                       if cnt > 0
                          then emptyDoc
                          else "generate"
  genStmt False   = do genDepth -= 1
                       cnt <- use genDepth
                       if cnt > 0
                          then emptyDoc
                          else "endgenerate"
  inst            = inst_
  expr            = expr_
  iwWidth         = use intWidth
  toBV hty id_    = toSLV hty (Identifier id_ Nothing)
  fromBV hty id_  = simpleFromSLV hty id_
  hdlSyn          = use hdlsyn
  mkIdentifier    = return go
    where
      go Basic    nm = filterReserved (mkBasicId' True nm)
      go Extended (rmSlash . escapeTemplate -> nm) = case go Basic nm of
        nm' | nm /= nm' -> Text.concat ["\\",nm," "]
            |otherwise  -> nm'
  extendIdentifier = return go
    where
      go Basic nm ext = filterReserved (mkBasicId' True (nm `Text.append` ext))
      go Extended (rmSlash -> nm) ext =
        let nmExt = nm `Text.append` ext
        in  case go Basic nm ext of
              nm' | nm' /= nmExt -> case Text.head nmExt of
                      '#' -> Text.concat ["\\",nmExt," "]
                      _   -> Text.concat ["\\#",nmExt," "]
                  | otherwise    -> nm'

  setModName nm s = s {_modNm = nm}
  setSrcSpan      = (srcSpan .=)
  getSrcSpan      = use srcSpan
  blockDecl _ ds  = do
    decs <- decls ds
    if isEmpty decs
      then insts ds
      else
        pure decs <> line <>
        insts ds
  unextend = return rmSlash
  addIncludes inc = includes %= (inc++)
  addLibraries _ = return ()
  addImports inps = imports %= (inps ++)
  addAndSetData f = do
    fs <- use dataFiles
    let (fs',f') = renderFilePath fs f
    dataFiles .= fs'
    return f'
  getDataFiles = use dataFiles
  addMemoryDataFile f = memoryDataFiles %= (f:)
  getMemoryDataFiles = use memoryDataFiles
  seenIdentifiers = idSeen

rmSlash :: Identifier -> Identifier
rmSlash nm = fromMaybe nm $ do
  nm1 <- Text.stripPrefix "\\" nm
  pure (Text.filter (not . (== ' ')) nm1)

type SystemVerilogM a = Mon (State SystemVerilogState) a

-- List of reserved SystemVerilog-2012 keywords
reservedWords :: [Identifier]
reservedWords = ["accept_on","alias","always","always_comb","always_ff"
  ,"always_latch","and","assert","assign","assume","automatic","before","begin"
  ,"bind","bins","binsof","bit","break","buf","bufif0","bufif1","byte","case"
  ,"casex","casez","cell","chandle","checker","class","clocking","cmos","config"
  ,"const","constraint","context","continue","cover","covergroup","coverpoint"
  ,"cross","deassign","default","defparam","design","disable","dist","do","edge"
  ,"else","end","endcase","endchecker","endclass","endclocking","endconfig"
  ,"endfunction","endgenerate","endgroup","endinterface","endmodule","endpackage"
  ,"endprimitive","endprogram","endproperty","endspecify","endsequence"
  ,"endtable","endtask","enum","event","eventually","expect","export","extends"
  ,"extern","final","first_match","for","force","foreach","forever","fork"
  ,"forkjoin","function","generate","genvar","global","highz0","highz1","if"
  ,"iff","ifnone","ignore_bins","illegal_bins","implements","implies","import"
  ,"incdir","include","initial","inout","input","inside","instance","int"
  ,"integer","interconnect","interface","intersect","join","join_any"
  ,"join_none","large","let","liblist","library","local","localparam","logic"
  ,"longint","macromodule","matches","medium","modport","module","nand"
  ,"negedge","nettype","new","nexttime","nmos","nor","noshowcancelled","not"
  ,"notif0","notif1","null","or","output","package","packed","parameter","pmos"
  ,"posedge","primitive","priority","program","property","protected","pull0"
  ,"pull1","pulldown","pullup","pulsestyle_ondetect","pulsestyle_onevent"
  ,"pure","rand","randc","randcase","randsequence","rcmos","real","realtime"
  ,"ref","reg","reject_on","release","repeat","restrict","return","rnmos"
  ,"rpmos","rtran","rtranif0","rtranif1","s_always","s_eventually","s_nexttime"
  ,"s_until","s_until_with","scalared","sequence","shortint","shortreal"
  ,"showcancelled","signed","small","soft","solve","specify","specparam"
  ,"static","string","strong","strong0","strong1","struct","super","supply0"
  ,"supply1","sync_accept_on","sync_reject_on","table","tagged","task","this"
  ,"throughout","time","timeprecision","timeunit","tran","tranif0","tranif1"
  ,"tri","tri0","tri1","triand","trior","trireg","type","typedef","union"
  ,"unique","unique0","unsigned","until","until_with","untyped","use","uwire"
  ,"var","vectored","virtual","void","wait","wait_order","wand","weak","weak0"
  ,"weak1","while","wildcard","wire","with","within","wor","xnor","xor"]

filterReserved :: Identifier -> Identifier
filterReserved s = if s `elem` reservedWords
  then s `Text.append` "_r"
  else s

-- | Generate SystemVerilog for a Netlist component
genVerilog :: String -> SrcSpan -> [Identifier] -> Component -> SystemVerilogM ((String,Doc),[(String,Doc)])
genVerilog _ sp seen c = preserveSeen $ do
    Mon $ idSeen .= seen
    Mon $ setSrcSpan sp
    v    <- verilog
    incs <- Mon $ use includes
    return ((unpack cName,v),incs)
  where
    cName   = componentName c
    verilog = commentHeader <> line <>
              module_ c
#ifdef CABAL
    clashVer = Data.Version.showVersion Paths_clash_lib.version
#else
    clashVer = "development"
#endif
    commentHeader
         = "/* AUTOMATICALLY GENERATED SYSTEMVERILOG-2005 SOURCE CODE."
      <> line <> "** GENERATED BY CLASH " <> string (Text.pack clashVer) <> ". DO NOT MODIFY."
      <> line <> "*/"

-- | Generate a SystemVerilog package containing type definitions for the given HWTypes
mkTyPackage_ :: String
             -> [HWType]
             -> SystemVerilogM [(String,Doc)]
mkTyPackage_ modName hwtys =
    (:[]) A.<$> (modName ++ "_types",) A.<$>
       "package" <+> modNameD <> "_types" <> semi <> line <>
         indent 2 packageDec <> line <>
         indent 2 funDecs <> line <>
       "endpackage" <+> colon <+> modNameD <> "_types"
  where
    modNameD    = string (pack modName)
    usedTys     = concatMap mkUsedTys hwtys
    needsDec    = nubBy eqReprTy $ (hwtys ++ usedTys)
    hwTysSorted = topSortHWTys needsDec
    packageDec  = vcat $ fmap catMaybes $ mapM tyDec hwTysSorted
    funDecs     = vcat $ fmap catMaybes $ mapM funDec hwTysSorted

    eqReprTy :: HWType -> HWType -> Bool
    eqReprTy (Vector n ty1) (Vector m ty2)
      | m == n    = eqReprTy ty1 ty2
      | otherwise = False
    eqReprTy (RTree n ty1) (RTree m ty2)
      | m == n    = eqReprTy ty1 ty2
      | otherwise = False
    eqReprTy Bit  ty2 = ty2 `elem` [Bit,Bool]
    eqReprTy Bool ty2 = ty2 `elem` [Bit,Bool]
    eqReprTy ty1 ty2
      | isUnsigned ty1 && isUnsigned ty2 = typeSize ty1 == typeSize ty2
      | otherwise                        = ty1 == ty2

    isUnsigned :: HWType -> Bool
    isUnsigned Bool                = True
    isUnsigned (Unsigned _)        = True
    isUnsigned (BitVector _)       = True
    isUnsigned (Index _)           = True
    isUnsigned (Sum _ _)           = True
    isUnsigned (CustomSum _ _ _ _) = True
    isUnsigned (SP _ _)            = True
    isUnsigned (CustomSP _ _ _ _)  = True
    isUnsigned _                   = False

mkUsedTys :: HWType
        -> [HWType]
mkUsedTys v@(Vector _ elTy)   = v : mkUsedTys elTy
mkUsedTys t@(RTree _ elTy)    = t : mkUsedTys elTy
mkUsedTys p@(Product _ elTys) = p : concatMap mkUsedTys elTys
mkUsedTys sp@(SP _ elTys)     = sp : concatMap mkUsedTys (concatMap snd elTys)
mkUsedTys c@(Clock _ _ Gated) = [c,Bit,Bool]
mkUsedTys t                   = [t]

topSortHWTys :: [HWType]
             -> [HWType]
topSortHWTys hwtys = sorted
  where
    nodes  = zip [0..] hwtys
    nodesI = HashMap.fromList (zip hwtys [0..])
    edges  = concatMap edge hwtys
    graph  = mkGraph nodes edges :: Gr HWType ()
    sorted = reverse $ topsort' graph

    edge t@(Vector _ elTy) = maybe [] ((:[]) . (HashMap.lookupDefault (error $ $(curLoc) ++ "Vector") t nodesI,,()))
                                      (HashMap.lookup elTy nodesI)
    edge t@(RTree _ elTy)  = maybe [] ((:[]) . (HashMap.lookupDefault (error $ $(curLoc) ++ "RTree") t nodesI,,()))
                                      (HashMap.lookup elTy nodesI)
    edge t@(Product _ tys) = let ti = HashMap.lookupDefault (error $ $(curLoc) ++ "Product") t nodesI
                             in mapMaybe (\ty -> liftM (ti,,()) (HashMap.lookup ty nodesI)) tys
    edge t@(SP _ ctys)     = let ti = HashMap.lookupDefault (error $ $(curLoc) ++ "SP") t nodesI
                             in concatMap (\(_,tys) -> mapMaybe (\ty -> liftM (ti,,()) (HashMap.lookup ty nodesI)) tys) ctys
    edge _                 = []

range :: Either Int Int -> SystemVerilogM Doc
range (Left n)  = brackets (int (n-1) <> colon <> int 0)
range (Right n) = brackets (int 0 <> colon <> int (n-1))

tyDec :: HWType -> SystemVerilogM (Maybe Doc)
tyDec ty@(Vector n elTy) | typeSize ty > 0 = Just A.<$> do
  syn <- Mon hdlSyn
  case syn of
    Vivado -> case splitVecTy ty of
      Just ([Right n',Left n''],elTy') ->
        "typedef" <+> elTy' <+> brackets (int (n''-1) <> colon <> int 0) <+>
        tyName ty <+> brackets (int 0 <> colon <> int (n'-1)) <> semi
      _ ->
        "typedef" <+> "logic" <+> brackets (int (typeSize elTy - 1) <> colon <> int 0) <+>
        tyName ty <+> brackets (int 0 <> colon <> int (n-1)) <> semi
    _ -> case splitVecTy ty of
      Just (Right n':ns,elTy') ->
        "typedef" <+> elTy' <+> hcat (mapM range ns) <+> tyName ty <+>
        brackets (int 0 <> colon <> int (n' - 1)) <> semi
      _ -> error $ $(curLoc) ++ "impossible"
tyDec ty@(RTree n elTy) | typeSize elTy > 0 = Just A.<$> do
  syn <- Mon hdlSyn
  case syn of
    Vivado -> case splitVecTy ty of
      Just ([Right n',Left n''],elTy') -> -- n' == 2^n
        "typedef" <+> elTy' <+> brackets (int 0 <> colon <> int (n''-1)) <+>
        tyName ty <+> brackets (int 0 <> colon <> int (n'-1)) <> semi
      _ ->
        "typedef" <+> "logic" <+> brackets (int (typeSize elTy - 1) <> colon <> int 0) <+>
        tyName ty <+> brackets (int 0 <> colon <> int (2^n-1)) <> semi
    _ -> case splitVecTy ty of
      Just (Right n':ns,elTy') -> -- n' == 2^n
        "typedef" <+> elTy' <+> hcat (mapM range ns) <+> tyName ty <+>
        brackets (int 0 <> colon <> int (n' - 1)) <> semi
      _ -> error $ $(curLoc) ++ "impossible"
tyDec ty@(Product _ tys) | typeSize ty > 0 = Just A.<$> prodDec
  where
    prodDec = "typedef struct packed {" <> line <>
                indent 2 (vcat $ fmap catMaybes $ zipWithM combineM selNames tys) <> line <>
              "}" <+> tName <> semi

    combineM x y = do
      yM <- lvType y
      case yM of
        Nothing -> pure Nothing
        Just y' -> Just A.<$> (pure y' <+> x <> semi)
    tName    = tyName ty
    selNames = map (\i -> tName <> "_sel" <> int i) [0..]

tyDec _ = pure Nothing

gatedClockType :: HWType -> HWType
gatedClockType (Clock nm rt Gated) = Product ("GatedClock" `Text.append` (pack (show (nm,rt)))) [Bit,Bool]
gatedClockType ty = ty
{-# INLINE gatedClockType #-}

splitVecTy :: HWType -> Maybe ([Either Int Int],SystemVerilogM Doc)
splitVecTy = fmap splitElemTy . go
  where
    splitElemTy (ns,t) = case t of
      Product _ _ -> (ns, verilogType t)
      Vector _ _  -> error $ $(curLoc) ++ "impossible"
      Clock {}    -> (ns, verilogType t)
      Reset {}    -> (ns, "logic")
      Bool        -> (ns, "logic")
      Bit         -> (ns, "logic")
      String      -> (ns, "string")
      Signed n    -> (ns ++ [Left n],"logic signed")
      _           -> (ns ++ [Left (typeSize t)], "logic")

    go (Vector n elTy) = case go elTy of
      Just (ns,elTy') -> Just (Right n:ns,elTy')
      _               -> Just ([Right n],elTy)

    go (RTree n elTy) = let n' = 2^n in case go elTy of
      Just (ns,elTy') -> Just (Right n':ns,elTy')
      _               -> Just ([Right n'],elTy)

    go _ = Nothing

lvType :: HWType -> SystemVerilogM (Maybe Doc)
lvType ty@(Vector n elTy) | typeSize ty > 0 = Just A.<$> do
  syn <- Mon hdlSyn
  case syn of
    Vivado -> "logic" <+> brackets (int 0 <> colon <> int (n-1)) <> brackets (int (typeSize elTy - 1) <> colon <> int 0)
    _ -> case splitVecTy ty of
      Just (ns,elTy') -> elTy' <> hcat (mapM range ns)
      _ -> error $ $(curLoc) ++ "impossible"
lvType ty@(RTree n elTy) | typeSize elTy > 0 = Just A.<$> do
  syn <- Mon hdlSyn
  case syn of
    Vivado -> "logic" <+> brackets (int 0 <> colon <> int (2^n-1)) <> brackets (int (typeSize elTy - 1) <> colon <> int 0)
    _ -> case splitVecTy ty of
      Just (ns,elTy') -> elTy' <> hcat (mapM range ns)
      _ -> error $ $(curLoc) ++ "impossible"
lvType ty | typeSize ty > 0 = Just A.<$> verilogType ty
lvType _ = pure Nothing

funDec :: HWType -> SystemVerilogM (Maybe Doc)
funDec ty@(Vector n elTy) | typeSize ty > 0 = Just A.<$>
  "function" <+> "logic" <+> ranges <+> tName <> "_to_lv" <> parens (sigDecl "i" ty) <> semi <> line <>
  indent 2
    ("for" <+> parens ("int n = 0" <> semi <+> "n <" <+> int n <> semi <+> "n=n+1") <> line <>
      indent 2 (tName <> "_to_lv" <> brackets "n" <+> "=" <+> "i[n]" <> semi)) <> line <>
  "endfunction" <> line <>
  "function" <+> tName <+> tName <> "_from_lv" <> parens ("logic" <+> ranges <+> "i") <> semi <> line <>
  indent 2
    ("for" <+> parens ("int n = 0" <> semi <+> "n <" <+> int n <> semi <+> "n=n+1") <> line <>
      indent 2 (tName <> "_from_lv" <> brackets "n" <+> "=" <+> "i[n]" <> semi)) <> line <>
  "endfunction" <> line <>
  if n > 1 then
    "function" <+> tName <+> tName <> "_cons" <> parens (sigDecl "x" elTy <> comma <> vecSigDecl "xs") <> semi <> line <>
    indent 2
      (tName <> "_cons" <> brackets (int 0) <+> "=" <+> (toSLV elTy (Identifier "x" Nothing)) <> semi <> line <>
       tName <> "_cons" <> brackets (int 1 <> colon <> int (n-1)) <+> "=" <+> "xs" <> semi) <> line <>
    "endfunction"
  else
    "function" <+> tName <+> tName <> "_cons" <> parens (sigDecl "x" elTy) <> semi <> line <>
    indent 2
      (tName <> "_cons" <> brackets (int 0) <+> "=" <+> (toSLV elTy (Identifier "x" Nothing)) <> semi) <> line <>
    "endfunction"
  where
    tName  = tyName ty
    ranges = brackets (int 0 <> colon <> int (n-1)) <>
             brackets (int (typeSize elTy - 1) <> colon <> int 0)

    vecSigDecl :: SystemVerilogM Doc -> SystemVerilogM Doc
    vecSigDecl d = do
      syn <- Mon hdlSyn
      case syn of
        Vivado -> case splitVecTy ty of
          Just ([Right n',Left n''],elTy') ->
            elTy' <+> brackets (int 0 <> colon <> int (n''-1)) <+>
            d <+> brackets (int 0 <> colon <> int (n'-2))
          _ ->
            "logic" <+> brackets (int (typeSize elTy - 1) <> colon <> int 0) <+>
            d <+> brackets (int 0 <> colon <> int (n-2))
        _ -> case splitVecTy ty of
         Just (Right n':ns,elTy') ->
           elTy' <+> hcat (mapM range ns) <+> d <+>
           brackets (int 0 <> colon <> int (n' - 2))
         _ -> error $ $(curLoc) ++ "impossible"


funDec ty@(RTree n elTy) | typeSize elTy > 0 = Just A.<$>
  "function" <+> "logic" <+> ranges <+> tName <> "_to_lv" <> parens (sigDecl "i" ty) <> semi <> line <>
  indent 2
    ("for" <+> parens ("int n = 0" <> semi <+> "n <" <+> int (2^n) <> semi <+> "n=n+1") <> line <>
      indent 2 (tName <> "_to_lv" <> brackets "n" <+> "=" <+> "i[n]" <> semi)) <> line <>
  "endfunction" <> line <>
  "function" <+> tName <+> tName <> "_from_lv" <> parens ("logic" <+> ranges <+> "i") <> semi <> line <>
  indent 2
    ("for" <+> parens ("int n = 0" <> semi <+> "n <" <+> int (2^n) <> semi <+> "n=n+1") <> line <>
      indent 2 (tName <> "_from_lv" <> brackets "n" <+> "=" <+> "i[n]" <> semi)) <> line <>
  "endfunction" <> line <>
  (if n > 0
      then
        "function" <+> tName <+> tName <> "_br" <> parens (treeSigDecl "l" <> comma <> treeSigDecl "r") <> semi <> line <>
        indent 2
          (tName <> "_br" <> brackets (int 0 <> colon <> int (2^(n-1)-1)) <+> "=" <+> "l" <> semi <> line <>
           tName <> "_br" <> brackets (int (2^(n-1)) <> colon <> int (2^n-1)) <+> "=" <+> "r" <> semi) <> line <>
        "endfunction"
      else
        emptyDoc)
  where
    treeSigDecl :: SystemVerilogM Doc -> SystemVerilogM Doc
    treeSigDecl d = do
      syn <- Mon hdlSyn
      case syn of
        Vivado -> case splitVecTy (RTree (n-1) elTy) of
          Just ([Right n',Left n''],elTy') -> -- n' == 2 ^ (n-1)
            elTy' <+> brackets (int 0 <> colon <> int (n''-1)) <+>
            d <+> brackets (int 0 <> colon <> int (n' - 1))
          _ ->
            "logic" <+> brackets (int (typeSize elTy - 1) <> colon <> int 0) <+>
            d <+> brackets (int 0 <> colon <> int (2^(n-1)-1))
        _ -> case splitVecTy (RTree (n-1) elTy) of
          Just (Right n':ns,elTy') -> -- n' == 2 ^ (n-1)
            elTy' <+> hcat (mapM range ns) <+> d <+>
            brackets (int 0 <> colon <> int (n' - 1))
          _ -> error $ $(curLoc) ++ "impossible"

    tName  = tyName ty
    ranges = brackets (int 0 <> colon <> int (2^n-1)) <>
             brackets (int (typeSize elTy - 1) <> colon <> int 0)

funDec _ = pure Nothing

module_ :: Component -> SystemVerilogM Doc
module_ c =
  addSeen c *> modVerilog <* Mon (imports .= [] >> oports .= [])
 where
  modVerilog = do
    body <- modBody
    imps <- Mon $ use imports
    modHeader <> line <> modPorts <> line <> include (nub imps) <> pure body <> line <> modEnding

  modHeader  = "module" <+> string (componentName c)
  modPorts   = indent 4 (tupleInputs inPorts <> line <> tupleOutputs outPorts <> semi)
  modBody    = indent 2 (decls (declarations c)) <> line <> line <> insts (declarations c)
  modEnding  = "endmodule"

  inPorts  = sequence [ sigPort (Nothing,isBiSignalIn ty) (i,ty) | (i,ty)  <- inputs c  ]
  outPorts = sequence [ sigPort (Just wr,False) p | (wr, p) <- outputs c ]

  wr2ty (Nothing,isBidirectional)
    | isBidirectional
    = "inout"
    | otherwise
    = "input"
  wr2ty (Just _,_)
    = "output"

  -- map a port to its verilog type, port name, and any encoding notes
  sigPort (wr2ty -> portTy) (nm, hwTy)
    = addAttrs (hwTypeAttrs hwTy)
        (portTy <+> sigDecl (string nm) hwTy <+> encodingNote hwTy)
  -- slightly more readable than 'tupled', makes the output Haskell-y-er
  commafy v = (comma <> space) <> pure v

  tupleInputs v = v >>= \case
    []     -> lparen <+> string "// No inputs" <> line
    (x:xs) -> lparen <+> string "// Inputs"
                    <> line <> (string "  " <> pure x)
                    <> line <> vcat (forM xs commafy)
                    <> line

  tupleOutputs v = v >>= \case
    []     -> string "  // No outputs" <> line <> rparen
    (x:xs) -> string "  // Outputs"
                <> line <> (if (length (inputs c)) > 0
                       then comma <> space <> pure x
                       else string "  " <> pure x)
                <> (if null xs then emptyDoc else line <> vcat (forM xs commafy))
                <> line <> rparen

addSeen :: Component -> SystemVerilogM ()
addSeen c = do
  let iport = map fst (inputs c)
      oport = map (fst.snd) $ outputs c
      nets  = mapMaybe (\case {NetDecl' _ _ i _ -> Just i; _ -> Nothing}) $ declarations c
  Mon (idSeen .= concat [iport,oport,nets])
  Mon (oports .= oport)

mkUniqueId :: Identifier -> SystemVerilogM Identifier
mkUniqueId i = do
  mkId <- Mon (mkIdentifier <*> pure Extended)
  seen <- Mon $ use idSeen
  let i' = mkId i
  case i `elem` seen of
    True  -> go mkId seen i' 0
    False -> do Mon (idSeen %= (i':))
                return i'
  where
    go :: (Identifier -> Identifier) -> [Identifier] -> Identifier
       -> Int -> SystemVerilogM Identifier
    go mkId seen i' n = do
      let i'' = mkId (Text.append i' (Text.pack ('_':show n)))
      case i'' `elem` seen of
        True  -> go mkId seen i' (n+1)
        False -> do Mon (idSeen %= (i'':))
                    return i''

verilogType :: HWType -> SystemVerilogM Doc
verilogType t = do
  Mon (tyCache %= HashSet.insert t)
  let logicOrWire | isBiSignalIn t = "wire"
                  | otherwise      = "logic"
  case t of
    Product _ _   -> do
      nm <- Mon $ use modNm
      string (pack nm) <> "_types::" <> tyName t
    Vector _ _ -> do
      nm <- Mon $ use modNm
      string (pack nm) <> "_types::" <> tyName t
    RTree _ _ -> do
      nm <- Mon $ use modNm
      string (pack nm) <> "_types::" <> tyName t
    Signed n      -> logicOrWire <+> "signed" <+> brackets (int (n-1) <> colon <> int 0)
    Clock _ _ Gated -> verilogType (gatedClockType t)
    Clock {}      -> "logic"
    Reset {}      -> "logic"
    Bit           -> "logic"
    Bool          -> "logic"
    String        -> "string"
    _ -> logicOrWire <+> brackets (int (typeSize t -1) <> colon <> int 0)

sigDecl :: SystemVerilogM Doc -> HWType -> SystemVerilogM Doc
sigDecl d t = verilogType t <+> d

-- | Convert a Netlist HWType to the root of a Verilog type
verilogTypeMark :: HWType -> SystemVerilogM Doc
verilogTypeMark t = do
  Mon (tyCache %= HashSet.insert t)
  nm <- Mon $ use modNm
  let m = tyName t
  case t of
    Product _ _ -> string (pack nm) <> "_types::" <> m
    Vector _ _ -> string (pack nm) <> "_types::" <> m
    RTree _ _ -> string (pack nm) <> "_types::" <> m
    _ -> emptyDoc

tyName :: HWType -> SystemVerilogM Doc
tyName Bool                  = "logic"
tyName Bit                   = "logic"
tyName (Vector n elTy)       = "array_of_" <> int n <> "_" <> tyName elTy
tyName (RTree n elTy)        = "tree_of_" <> int n <> "_" <> tyName elTy
tyName (BitVector n)         = "logic_vector_" <> int n
tyName t@(Index _)           = "logic_vector_" <> int (typeSize t)
tyName (Signed n)            = "signed_" <> int n
tyName (Unsigned n)          = "logic_vector_" <> int n
tyName t@(Sum _ _)           = "logic_vector_" <> int (typeSize t)
tyName t@(CustomSum _ _ _ _) = "logic_vector_" <> int (typeSize t)
tyName t@(CustomSP _ _ _ _)  = "logic_vector_" <> int (typeSize t)
tyName t@(Product nm _)      = Mon (makeCached t nameCache prodName)
  where
    prodName = do
      seen <- use tySeen
      mkId <- mkIdentifier <*> pure Basic
      let nm'  = (mkId . last . Text.splitOn ".") nm
          nm'' = if Text.null nm'
                    then "product"
                    else nm'
          nm3  = if nm'' `elem` seen
                    then go mkId seen (0::Integer) nm''
                    else nm''
      tySeen %= (nm3:)
      string nm3

    go mkId s i n =
      let n' = n `Text.append` Text.pack ('_':show i)
      in  if n' `elem` s
             then go mkId s (i+1) n
             else n'
tyName t@(SP _ _)  = "logic_vector_" <> int (typeSize t)
tyName t@(Clock _ _ Gated) = tyName (gatedClockType t)
tyName (Clock {})  = "logic"
tyName (Reset {})  = "logic"
tyName t =  error $ $(curLoc) ++ "tyName: " ++ show t

-- | Convert a Netlist HWType to an error SystemVerilog value for that type
verilogTypeErrValue :: HWType -> SystemVerilogM Doc
verilogTypeErrValue (Vector n elTy) = do
  syn <- Mon hdlSyn
  case syn of
    Vivado -> char '\'' <> braces (int n <+> braces (braces (int (typeSize elTy) <+> braces "1'bx")))
    _ -> char '\'' <> braces (int n <+> braces (verilogTypeErrValue elTy))
verilogTypeErrValue (RTree n elTy) = do
  syn <- Mon hdlSyn
  case syn of
    Vivado -> char '\'' <> braces (int (2^n) <+> braces (braces (int (typeSize elTy) <+> braces "1'bx")))
    _ -> char '\'' <> braces (int (2^n) <+> braces (verilogTypeErrValue elTy))
verilogTypeErrValue String = "\"ERROR\""
verilogTypeErrValue ty  = braces (int (typeSize ty) <+> braces "1'bx")

verilogRecSel
  :: HWType
  -> Int
  -> SystemVerilogM Doc
verilogRecSel ty i = tyName ty <> "_sel" <> int i

decls :: [Declaration] -> SystemVerilogM Doc
decls [] = emptyDoc
decls ds = do
    dsDoc <- catMaybes A.<$> mapM decl ds
    case dsDoc of
      [] -> emptyDoc
      _  -> punctuate' semi (A.pure dsDoc)

decl :: Declaration -> SystemVerilogM (Maybe Doc)
decl (NetDecl' noteM _ id_ tyE) =
  Just A.<$> maybe id addNote noteM (addAttrs attrs (typ tyE))
  where
    typ (Left  ty) = string ty <+> string id_
    typ (Right ty) = sigDecl (string id_) ty
    addNote n = mappend ("//" <+> string n <> line)
    attrs = fromMaybe [] (hwTypeAttrs A.<$> either (const Nothing) Just tyE)

decl _ = return Nothing

-- | Convert single attribute to systemverilog syntax
renderAttr :: Attr' -> Text.Text
renderAttr (StringAttr'  key value) = pack $ concat [key, " = ", show value]
renderAttr (IntegerAttr' key value) = pack $ concat [key, " = ", show value]
renderAttr (BoolAttr'    key True ) = pack $ concat [key, " = ", "1"]
renderAttr (BoolAttr'    key False) = pack $ concat [key, " = ", "0"]
renderAttr (Attr'        key      ) = pack $ key

-- | Add attribute notation to given declaration
addAttrs
  :: [Attr']
  -> SystemVerilogM Doc
  -> SystemVerilogM Doc
addAttrs []     t = t
addAttrs attrs' t =
  "(*" <+> attrs'' <+> "*)" <+> t
    where
      attrs'' = string $ intercalate ", " (map renderAttr attrs')

insts :: [Declaration] -> SystemVerilogM Doc
insts [] = emptyDoc
insts is = indent 2 . vcat . punctuate line . fmap catMaybes $ mapM inst_ is

stdMatch
  :: Bits a
  => Int
  -> a
  -> a
  -> String
stdMatch 0 _mask _value = []
stdMatch size mask value =
  symbol : stdMatch (size - 1) mask value
  where
    symbol =
      if testBit mask (size - 1) then
        if testBit value (size - 1) then
          '1'
        else
          '0'
      else
        '?'

patLitCustom'
  :: Int
  -> ConstrRepr'
  -> SystemVerilogM Doc
patLitCustom' size (ConstrRepr' _name _n mask value _anns) =
  int size <> squote <> "b" <> (string $ Text.pack $ stdMatch size mask value)

patLitCustom
  :: HWType
  -> Literal
  -> SystemVerilogM Doc
patLitCustom (CustomSum _name _dataRepr size reprs) (NumLit (fromIntegral -> i)) =
  patLitCustom' size (fst $ reprs !! i)

patLitCustom (CustomSP _name _dataRepr size reprs) (NumLit (fromIntegral -> i)) =
  let (cRepr, _id, _tys) = reprs !! i in
  patLitCustom' size cRepr

patLitCustom x y = error $ $(curLoc) ++ unwords
  [ "You can only pass CustomSP / CustomSum and a NumLit to this function,"
  , "not", show x, "and", show y]

patMod :: HWType -> Literal -> Literal
patMod hwTy (NumLit i) = NumLit (i `mod` (2 ^ typeSize hwTy))
patMod _ l = l

-- | Helper function for inst_, handling CustomSP and CustomSum
inst_' :: Text.Text -> Expr -> HWType -> [(Maybe Literal, Expr)] -> SystemVerilogM (Maybe Doc)
inst_' id_ scrut scrutTy es = fmap Just $
  "always_comb begin" <> line <> indent 2 casez <> line <> "end"
    where
      casez =
        "casez" <+> parens var <> line <>
          indent 2 (conds esNub) <> line <>
        "endcase"

      esMod = map (first (fmap (patMod scrutTy))) es
      esNub = nubBy ((==) `on` fst) esMod
      var   = expr_ True scrut

      conds :: [(Maybe Literal,Expr)] -> SystemVerilogM Doc
      conds []                = error $ $(curLoc) ++ "Empty list of conditions invalid."
      conds [(_,e)]           = "default" <+> ":" <+> string id_ <+> "=" <+> expr_ False e <> ";"
      conds ((Nothing,e):_)   = "default" <+> ":" <+> string id_ <+> "=" <+> expr_ False e <> ";"
      conds ((Just c ,e):es') =
        mask' <+> ":" <+> string id_ <+> "=" <+> expr_ False e <> ";" <> line <> conds es'
          where
            mask' = patLitCustom scrutTy c

-- | Turn a Netlist Declaration to a SystemVerilog concurrent block
inst_ :: Declaration -> SystemVerilogM (Maybe Doc)
inst_ (Assignment id_ e) = fmap Just $
  "assign" <+> string id_ <+> equals <+> align (expr_ False e <> semi)

inst_ (CondAssignment id_ ty scrut _ [(Just (BoolLit b), l),(_,r)]) = fmap Just $ do
    { syn <- Mon hdlSyn
    ; p   <- Mon $ use oports
    ; if syn == Vivado && id_ `elem` p
         then do
              { regId <- mkUniqueId =<< Mon (extendIdentifier <*> pure Extended <*> pure id_ <*> pure "_reg")
              ; verilogType ty <+> string regId <> semi <> line <>
                "always_comb begin" <> line <>
                indent 2 ("if" <> parens (expr_ True scrut) <> line <>
                            (indent 2 $ string regId <+> equals <+> expr_ False t <> semi) <> line <>
                         "else" <> line <>
                            (indent 2 $ string regId <+> equals <+> expr_ False f <> semi)) <> line <>
                "end" <> line <>
                "assign" <+> string id_ <+> equals <+> string regId <> semi
              }
         else "always_comb begin" <> line <>
              indent 2 ("if" <> parens (expr_ True scrut) <> line <>
                          (indent 2 $ string id_ <+> equals <+> expr_ False t <> semi) <> line <>
                       "else" <> line <>
                          (indent 2 $ string id_ <+> equals <+> expr_ False f <> semi)) <> line <>
              "end"
    }
  where
    (t,f) = if b then (l,r) else (r,l)

inst_ (CondAssignment id_ _ scrut scrutTy@(CustomSP _ _ _ _) es) =
  inst_' id_ scrut scrutTy es

inst_ (CondAssignment id_ _ scrut scrutTy@(CustomSum _ _ _ _) es) =
  inst_' id_ scrut scrutTy es

inst_ (CondAssignment id_ ty scrut scrutTy es) = fmap Just $ do
    { syn <- Mon hdlSyn
    ; p <- Mon $ use oports
    ; if syn == Vivado && id_ `elem` p
         then do
           { regId <- mkUniqueId =<< Mon (extendIdentifier <*> pure Extended <*> pure id_ <*> pure "_reg")
           ; verilogType ty <+> string regId <> semi <> line <>
             "always_comb begin" <> line <>
             indent 2 ("case" <> parens (expr_ True scrut) <> line <>
                         (indent 2 $ vcat $ punctuate semi (conds regId es)) <> semi <> line <>
                       "endcase") <> line <>
             "end" <> line <>
             "assign" <+> string id_ <+> equals <+> string regId <> semi
           }
         else "always_comb begin" <> line <>
              indent 2 ("case" <> parens (expr_ True scrut) <> line <>
                          (indent 2 $ vcat $ punctuate semi (conds id_ es)) <> semi <> line <>
                        "endcase") <> line <>
              "end"
    }
  where
    conds :: Identifier -> [(Maybe Literal,Expr)] -> SystemVerilogM [Doc]
    conds _ []                = return []
    conds i [(_,e)]           = ("default" <+> colon <+> string i <+> equals <+> expr_ False e) <:> return []
    conds i ((Nothing,e):_)   = ("default" <+> colon <+> string i <+> equals <+> expr_ False e) <:> return []
    conds i ((Just c ,e):es') = (exprLit (Just (scrutTy,conSize scrutTy)) c <+> colon <+> string i <+> equals <+> expr_ False e) <:> conds i es'

inst_ (InstDecl _ _ nm lbl pms) = fmap Just $
    nest 2 (string nm <+> string lbl <> line <> pms' <> semi)
  where
    pms' = tupled $ sequence [dot <> expr_ False i <+> parens (expr_ False e) | (i,_,_,e) <- pms]

inst_ (BlackBoxD _ libs imps inc bs bbCtx) =
  fmap Just (Mon (column (renderBlackBox libs imps inc bs bbCtx)))

inst_ (NetDecl' _ _ _ _) = return Nothing

-- | Turn a Netlist expression into a SystemVerilog expression
expr_ :: Bool -- ^ Enclose in parenthesis?
      -> Expr -- ^ Expr to convert
      -> SystemVerilogM Doc
expr_ _ (Literal sizeM lit)                           = exprLit sizeM lit
expr_ _ (Identifier id_ Nothing)                      = string id_
expr_ _ (Identifier id_ (Just (Indexed (CustomSP _id _dataRepr _size args,dcI,fI)))) =
  expFromSLV resultType (braces $ hcat $ punctuate ", " $ sequence ranges)
    where
      (ConstrRepr' _name _n _mask _value anns, _, argTys) = args !! dcI
      resultType = argTys !! fI
      ranges = map range' $ bitRanges (anns !! fI)
      range' (start, end) = string id_ <> brackets (int start <> ":" <> int end)
expr_ _ (Identifier id_ (Just (Indexed (ty@(SP _ args),dcI,fI)))) = fromSLV argTy id_ start end
  where
    argTys   = snd $ args !! dcI
    argTy    = argTys !! fI
    argSize  = typeSize argTy
    other    = otherSize argTys (fI-1)
    start    = typeSize ty - 1 - conSize ty - other
    end      = start - argSize + 1

expr_ _ (Identifier id_ (Just (Indexed (ty@(Product _ tys),_,fI)))) = do
  id'<- fmap renderOneLine (string id_ <> dot <> tyName ty <> "_sel" <> int fI)
  simpleFromSLV (tys !! fI) id'

expr_ _ (Identifier id_ (Just (Indexed (ty@(Clock _ _ Gated),_,fI)))) = do
  let tys = [Bit, Bool]
      ty' = gatedClockType ty
  id'<- fmap renderOneLine (string id_ <> dot <> tyName ty' <> "_sel" <> int fI)
  simpleFromSLV (tys !! fI) id'

expr_ _ (Identifier id_ (Just (Indexed ((Vector _ elTy),1,0)))) = do
  id' <- fmap renderOneLine (string id_ <> brackets (int 0))
  simpleFromSLV elTy id'

expr_ _ (Identifier id_ (Just (Indexed ((Vector n _),1,1)))) = string id_ <> brackets (int 1 <> colon <> int (n-1))

-- This is a "Hack", we cannot construct trees with a negative depth. This is
-- here so that we can recognise merged RTree modifiers. See the code in
-- @Clash.Backend.nestM@ which construct these tree modifiers.
expr_ _ (Identifier id_ (Just (Indexed (RTree (-1) _,l,r)))) =
  string id_ <> brackets (int l <> colon <> int (r-1))

expr_ _ (Identifier id_ (Just (Indexed ((RTree 0 elTy),0,0)))) = do
  id' <- fmap renderOneLine (string id_ <> brackets (int 0))
  simpleFromSLV elTy id'

expr_ _ (Identifier id_ (Just (Indexed ((RTree n _),1,0)))) =
  let z = 2^(n-1)
  in  string id_ <> brackets (int 0 <> colon <> int (z-1))

expr_ _ (Identifier id_ (Just (Indexed ((RTree n _),1,1)))) =
  let z  = 2^(n-1)
      z' = 2^n
  in string id_ <> brackets (int z <> colon <> int (z'-1))

-- This is a HACK for Clash.Driver.TopWrapper.mkOutput
-- Vector's don't have a 10'th constructor, this is just so that we can
-- recognize the particular case
expr_ _ (Identifier id_ (Just (Indexed ((Vector _ elTy),10,fI)))) = do
  id' <- fmap renderOneLine (string id_ <> brackets (int fI))
  simpleFromSLV elTy id'

-- This is a HACK for Clash.Driver.TopWrapper.mkOutput
-- RTree's don't have a 10'th constructor, this is just so that we can
-- recognize the particular case
expr_ _ (Identifier id_ (Just (Indexed ((RTree _ elTy),10,fI)))) = do
  id' <- fmap renderOneLine (string id_ <> brackets (int fI))
  simpleFromSLV elTy id'

expr_ _ (Identifier id_ (Just (DC (ty@(SP _ _),_)))) = string id_ <> brackets (int start <> colon <> int end)
  where
    start = typeSize ty - 1
    end   = typeSize ty - conSize ty

expr_ b (Identifier id_ (Just (Nested m1 m2))) = case nestM m1 m2 of
  Just m3 -> expr_ b (Identifier id_ (Just m3))
  _ -> do
    k <- expr_ b (Identifier id_ (Just m1))
    expr_ b (Identifier (renderOneLine k) (Just m2))

-- See [Note] integer projection
expr_ _ (Identifier id_ (Just (Indexed ((Signed w),_,_))))  = do
  iw <- Mon $ use intWidth
  traceIf (iw < w) ($(curLoc) ++ "WARNING: result smaller than argument") $
    string id_

-- See [Note] integer projection
expr_ _ (Identifier id_ (Just (Indexed ((Unsigned w),_,_))))  = do
  iw <- Mon $ use intWidth
  traceIf (iw < w) ($(curLoc) ++ "WARNING: result smaller than argument") $
    string id_

-- See [Note] mask projection
expr_ _ (Identifier _ (Just (Indexed ((BitVector _),_,0)))) = do
  iw <- Mon $ use intWidth
  traceIf True ($(curLoc) ++ "WARNING: synthesizing bitvector mask to dontcare") $
    verilogTypeErrValue (Signed iw)

-- See [Note] bitvector projection
expr_ _ (Identifier id_ (Just (Indexed ((BitVector w),_,1)))) = do
  iw <- Mon $ use intWidth
  traceIf (iw < w) ($(curLoc) ++ "WARNING: result smaller than argument") $
    string id_

expr_ _ (Identifier id_ (Just _)) = string id_

expr_ b (DataCon _ (DC (Void {}, -1)) [e]) =  expr_ b e

expr_ _ (DataCon ty@(Vector 0 _) _ _) = verilogTypeErrValue ty

expr_ _ (DataCon (Vector 1 elTy) _ [e]) = "'" <> braces (toSLV elTy e)

expr_ _ e@(DataCon ty@(Vector _ elTy) _ [e1,e2]) = case vectorChain e of
  Just es -> "'" <> listBraces (mapM (toSLV elTy) es)
  Nothing -> verilogTypeMark ty <> "_cons" <> parens (expr_ False e1 <> comma <+> expr_ False e2)

expr_ _ (DataCon (RTree 0 elTy) _ [e]) = "'" <> braces (toSLV elTy e)

expr_ _ e@(DataCon ty@(RTree _ elTy) _ [e1,e2]) = case rtreeChain e of
  Just es -> "'" <> listBraces (mapM (toSLV elTy) es)
  Nothing -> verilogTypeMark ty <> "_br" <> parens (expr_ False e1 <> comma <+> expr_ False e2)

expr_ _ (DataCon ty@(SP _ args) (DC (_,i)) es) = assignExpr
  where
    argTys     = snd $ args !! i
    dcSize     = conSize ty + sum (map typeSize argTys)
    dcExpr     = expr_ False (dcToExpr ty i)
    argExprs   = zipWith toSLV argTys es
    extraArg   = case typeSize ty - dcSize of
                   0 -> []
                   n -> [int n <> "'b" <> bits (replicate n U)]
    assignExpr = braces (hcat $ punctuate comma $ sequence (dcExpr:argExprs ++ extraArg))

expr_ _ (DataCon ty@(Sum _ _) (DC (_,i)) []) = int (typeSize ty) <> "'d" <> int i
expr_ _ (DataCon ty@(CustomSum _ _ _ tys) (DC (_,i)) []) =
  let (ConstrRepr' _ _ _ value _) = fst $ tys !! i in
  int (typeSize ty) <> squote <> "d" <> int (fromIntegral value)
expr_ _ (DataCon (CustomSP _ dataRepr size args) (DC (_,i)) es) =
  braces $ hcat $ punctuate ", " $ mapM range' origins
    where
      (cRepr, _, argTys) = args !! i

      -- Build bit representations for all constructor arguments
      argExprs = zipWith toSLV argTys es :: [SystemVerilogM Doc]

      -- Spread bits of constructor arguments using masks
      origins = bitOrigins dataRepr cRepr :: [BitOrigin]

      range'
        :: BitOrigin
        -> SystemVerilogM Doc
      range' (Lit (bitsToBits -> ns)) =
        int (length ns) <> squote <> "b" <> hcat (mapM bit_char ns)
      range' (Field n start end) =
        -- We want to select the bits starting from 'start' downto and including
        -- 'end'. We cannot use slice notation in Verilog, as the preceding
        -- expression might not be an identifier.
        let fsize = start - end + 1 in
        let expr' = argExprs !! n in

        if | fsize == size ->
               -- If sizes are equal, rotating / resizing amounts to doing nothing
               expr'
           | end == 0 ->
               -- Rotating is not necessary if relevant bits are already at the end
               int fsize <> squote <> parens expr'
           | otherwise ->
               -- Select bits 'start' downto and including 'end'
               let rotated  = parens expr' <+> ">>" <+> int end in
               int fsize <> squote <> parens rotated
expr_ _ (DataCon (Product _ tys) _ es) = listBraces (zipWithM toSLV tys es)
expr_ _ (DataCon (Clock nm rt Gated) _ es) =
  listBraces (zipWithM toSLV [Clock nm rt Source,Bool] es)

expr_ _ (BlackBoxE pNm _ _ _ _ bbCtx _)
  | pNm == "Clash.Sized.Internal.Signed.fromInteger#"
  , [Literal _ (NumLit n), Literal _ i] <- extractLiterals bbCtx
  = exprLit (Just (Signed (fromInteger n),fromInteger n)) i

expr_ _ (BlackBoxE pNm _ _ _ _ bbCtx _)
  | pNm == "Clash.Sized.Internal.Unsigned.fromInteger#"
  , [Literal _ (NumLit n), Literal _ i] <- extractLiterals bbCtx
  = exprLit (Just (Unsigned (fromInteger n),fromInteger n)) i

expr_ _ (BlackBoxE pNm _ _ _ _ bbCtx _)
  | pNm == "Clash.Sized.Internal.BitVector.fromInteger#"
  , [Literal _ (NumLit n), Literal _ (NumLit m), Literal _ (NumLit i)] <- extractLiterals bbCtx
  = exprLit (Just (BitVector (fromInteger n),fromInteger n)) (BitVecLit m i)

expr_ _ (BlackBoxE pNm _ _ _ _ bbCtx _)
  | pNm == "Clash.Sized.Internal.BitVector.fromInteger##"
  , [Literal _ m, Literal _ i] <- extractLiterals bbCtx
  = let NumLit m' = m
        NumLit i' = i
    in exprLit (Just (Bit,1)) (BitLit $ toBit m' i')

expr_ _ (BlackBoxE pNm _ _ _ _ bbCtx _)
  | pNm == "Clash.Sized.Internal.Index.fromInteger#"
  , [Literal _ (NumLit n), Literal _ i] <- extractLiterals bbCtx
  = exprLit (Just (Index (fromInteger n),fromInteger n)) i

expr_ b (BlackBoxE _ libs imps inc bs bbCtx b') =
  parenIf (b || b') (Mon (renderBlackBox libs imps inc bs bbCtx <*> pure 0))

expr_ _ (DataTag Bool (Left id_))          = string id_ <> brackets (int 0)
expr_ _ (DataTag Bool (Right id_))         = do
  iw <- Mon $ use intWidth
  "$unsigned" <> parens (listBraces (sequence [braces (int (iw-1) <+> braces "1'b0"),string id_]))

expr_ _ (DataTag (Sum _ _) (Left id_))     = "$unsigned" <> parens (string id_)
expr_ _ (DataTag (Sum _ _) (Right id_))    = "$unsigned" <> parens (string id_)

expr_ _ (DataTag (Product _ _) (Right _))  = do
  iw <- Mon $ use intWidth
  int iw <> "'sd0"

expr_ _ (DataTag hty@(SP _ _) (Right id_)) = "$unsigned" <> parens
                                               (string id_ <> brackets
                                               (int start <> colon <> int end))
  where
    start = typeSize hty - 1
    end   = typeSize hty - conSize hty

expr_ _ (DataTag (Vector 0 _) (Right _)) = do
  iw <- Mon $ use intWidth
  int iw <> "'sd0"
expr_ _ (DataTag (Vector _ _) (Right _)) = do
  iw <- Mon $ use intWidth
  int iw <> "'sd1"

expr_ _ (DataTag (RTree 0 _) (Right _)) = do
  iw <- Mon $ use intWidth
  int iw <> "'sd0"
expr_ _ (DataTag (RTree _ _) (Right _)) = do
  iw <- Mon $ use intWidth
  int iw <> "'sd1"

expr_ b (ConvBV topM t True e) = do
  nm <- Mon $ use modNm
  let nm' = string (pack nm)
  case t of
    Vector {} -> do
      Mon (tyCache %= HashSet.insert t)
      maybe (nm' <> "_types::" ) ((<> "_types::") . string) topM <>
        tyName t <> "_to_lv" <> parens (expr_ False e)
    RTree {} -> do
      Mon (tyCache %= HashSet.insert t)
      maybe (nm' <> "_types::" ) ((<> "_types::") . string) topM <>
        tyName t <> "_to_lv" <> parens (expr_ False e)
    _ -> expr b e

expr_ b (ConvBV topM t False e) = do
  nm <- Mon $ use modNm
  let nm' = string (pack nm)
  case t of
    Vector {} -> do
      Mon (tyCache %= HashSet.insert t)
      maybe (nm' <> "_types::" ) ((<> "_types::") . string) topM <>
        tyName t <> "_from_lv" <> parens (expr_ False e)
    RTree {} -> do
      Mon (tyCache %= HashSet.insert t)
      maybe (nm' <> "_types::" ) ((<> "_types::") . string) topM <>
        tyName t <> "_from_lv" <> parens (expr_ False e)
    _ -> expr b e

expr_ _ e = error $ $(curLoc) ++ (show e) -- empty

otherSize :: [HWType] -> Int -> Int
otherSize _ n | n < 0 = 0
otherSize []     _    = 0
otherSize (a:as) n    = typeSize a + otherSize as (n-1)

vectorChain :: Expr -> Maybe [Expr]
vectorChain (DataCon (Vector 0 _) _ _)        = Just []
vectorChain (DataCon (Vector 1 _) _ [e])     = Just [e]
vectorChain (DataCon (Vector _ _) _ [e1,e2]) = Just e1 <:> vectorChain e2
vectorChain _                                       = Nothing

rtreeChain :: Expr -> Maybe [Expr]
rtreeChain (DataCon (RTree 0 _) _ [e])     = Just [e]
rtreeChain (DataCon (RTree _ _) _ [e1,e2]) = A.liftA2 (++) (rtreeChain e1)
                                                           (rtreeChain e2)
rtreeChain _                               = Nothing

toSLV :: HWType -> Expr -> SystemVerilogM Doc
toSLV t e = case t of
  Vector _ _ -> braces (verilogTypeMark t <> "_to_lv" <> parens (expr_ False e))
  RTree _ _ -> braces (verilogTypeMark t <> "_to_lv" <> parens (expr_ False e))
  _ -> expr_ False e

fromSLV :: HWType -> Identifier -> Int -> Int -> SystemVerilogM Doc
fromSLV t@(Vector _ _) id_ start end = verilogTypeMark t <> "_from_lv" <> parens (string id_ <> brackets (int start <> colon <> int end))
fromSLV t@(RTree _ _) id_ start end = verilogTypeMark t <> "_from_lv" <> parens (string id_ <> brackets (int start <> colon <> int end))
fromSLV (Signed _) id_ start end = "$signed" <> parens (string id_ <> brackets (int start <> colon <> int end))
fromSLV _ id_ start end = string id_ <> brackets (int start <> colon <> int end)

simpleFromSLV :: HWType -> Identifier -> SystemVerilogM Doc
simpleFromSLV t@(Vector _ _) id_ = verilogTypeMark t <> "_from_lv" <> parens (string id_)
simpleFromSLV t@(RTree _ _) id_ = verilogTypeMark t <> "_from_lv" <> parens (string id_)
simpleFromSLV (Signed _) id_ = "$signed" <> parens (string id_)
simpleFromSLV _ id_ = string id_

expFromSLV :: HWType -> SystemVerilogM Doc -> SystemVerilogM Doc
expFromSLV t@(Vector _ _) exp_ = verilogTypeMark t <> "_from_lv" <> parens exp_
expFromSLV t@(RTree _ _) exp_ = verilogTypeMark t <> "_from_lv" <> parens exp_
expFromSLV (Signed _) exp_ = "$signed" <> parens exp_
expFromSLV _ exp_ = exp_

dcToExpr :: HWType -> Int -> Expr
dcToExpr ty i = Literal (Just (ty,conSize ty)) (NumLit (toInteger i))

listBraces :: Monad m => m [Doc] -> m Doc
listBraces = align . encloseSep lbrace rbrace comma

parenIf :: Monad m => Bool -> m Doc -> m Doc
parenIf True  = parens
parenIf False = id

punctuate' :: Monad m => Mon m Doc -> Mon m [Doc] -> Mon m Doc
punctuate' s d = vcat (punctuate s d) <> s

encodingNote :: HWType -> SystemVerilogM Doc
encodingNote (Clock _ _ Gated) = "// gated clock"
encodingNote (Clock {})        = "// clock"
encodingNote (Reset {})        = "// asynchronous reset: active high"
encodingNote _                 = emptyDoc
