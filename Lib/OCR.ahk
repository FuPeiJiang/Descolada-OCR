﻿#Requires AutoHotkey v2

/**
 * OCR library: a wrapper for the the UWP Windows.Media.Ocr library.
 * Based on the UWP OCR function for AHK v1 by malcev.
 * 
 * Ways of initiating OCR:
 * OCR(IRandomAccessStream, lang?)
 * OCR.FromDesktop(lang?, scale:=1)
 * OCR.FromRect(X, Y, W, H, lang?, scale:=1)
 * OCR.FromWindow(WinTitle?, lang?, scale:=1, onlyClientArea:=0, mode:=2)
 * OCR.FromFile(FileName, lang?)
 * OCR.FromBitmap(HBitmap, lang?)
 * 
 * Additional methods:
 * OCR.GetAvailableLanguages()
 * OCR.LoadLanguage(lang:="FirstFromAvailableLanguages")
 * 
 * OCR returns an OCR results object:
 * Text         => All recognized text
 * TextAngle    => Clockwise rotation of the recognized text 
 * Lines        => Array of all Line objects
 * Words        => Array of all Word objects
 * ImageWidth   => Used image width
 * ImageHeight  => Used image height
 * 
 * Line object:
 * Text         => Recognized text of the line
 * Words        => Array of Word objects for the Line
 * 
 * Word object:
 * Text         => Recognized text of the word
 * Location     => Location of the Word in format {x,y,w,h}. Coordinates are relative to the original image.
 * 
 * Additional notes:
 * Languages are recognized in BCP-47 language tags. Eg. OCR.FromFile("myfile.bmp", "en-AU")
 * Languages can be installed for example with PowerShell (run as admin): Install-Language <language-tag>
 *      or from Language settings in Settings.
 * Not all language packs support OCR though. A list of supported language can be gotten from 
 * Powershell (run as admin) with the following command: Get-WindowsCapability -Online | Where-Object { $_.Name -Like 'Language.OCR*' } 
 */
class OCR {
    static IID_IRandomAccessStream := "{905A0FE1-BC53-11DF-8C49-001E4FC686DA}"
         , IID_IPicture            := "{7BF80980-BF32-101A-8BBB-00AA00300CAB}"
         , IID_IAsyncInfo          := "{00000036-0000-0000-C000-000000000046}"

    class IBase {
        __New(ptr?) {
            if IsSet(ptr) && !ptr
                throw ValueError('Invalid IUnknown interface pointer', -2, this.__Class)
            this.DefineProp("ptr", {Value:ptr ?? 0})
        }
        __Delete() => this.ptr ? ObjRelease(this.ptr) : 0
    }

    static __New() {
        this.LanguageFactory := OCR.CreateClass("Windows.Globalization.Language", ILanguageFactory := "{9B0252AC-0C27-44F8-B792-9793FB66C63E}")
        this.BitmapDecoderStatics := OCR.CreateClass("Windows.Graphics.Imaging.BitmapDecoder", IBitmapDecoderStatics := "{438CCB26-BCEF-4E95-BAD6-23A822E58D01}")
        this.OcrEngineStatics := OCR.CreateClass("Windows.Media.Ocr.OcrEngine", IOcrEngineStatics := "{5BFFA85A-3384-3540-9940-699120D428A8}")
        ComCall(6, this.OcrEngineStatics, "uint*", &MaxImageDimension:=0)   ; MaxImageDimension
        this.MaxImageDimension := MaxImageDimension
    }

    /**
     * Returns an OCR results object for an IRandomAccessStream.
     * Images of other types should be first converted to this format (eg from file, from bitmap).
     * @param pIRandomAccessStream Pointer or an object containing a ptr to the stream
     * @param {String} lang OCR language. Default is first from available languages.
     * @returns {Ocr} 
     */
    __New(pIRandomAccessStream?, lang := "FirstFromAvailableLanguages") {
        if IsSet(lang) || !OCR.HasOwnProp("CurrentLanguage")
            OCR.LoadLanguage(lang?)

        ComCall(14, OCR.BitmapDecoderStatics, "ptr", pIRandomAccessStream, "ptr*", BitmapDecoder:=OCR.IBase())   ; CreateAsync
        OCR.WaitForAsync(&BitmapDecoder)
        BitmapFrame := ComObjQuery(BitmapDecoder, IBitmapFrame := "{72A49A1C-8081-438D-91BC-94ECFC8185C6}")
        ComCall(12, BitmapFrame, "uint*", &width:=0)   ; get_PixelWidth
        ComCall(13, BitmapFrame, "uint*", &height:=0)   ; get_PixelHeight
        if (width > OCR.MaxImageDimension) or (height > OCR.MaxImageDimension)
           throw ValueError("Image is to big - " width "x" height ".`nIt should be maximum - " OCR.MaxImageDimension " pixels")
        this.ImageWidth := width, this.ImageHeight := height

        BitmapFrameWithSoftwareBitmap := ComObjQuery(BitmapDecoder, IBitmapFrameWithSoftwareBitmap := "{FE287C9A-420C-4963-87AD-691436E08383}")
        ComCall(6, BitmapFrameWithSoftwareBitmap, "ptr*", SoftwareBitmap:=OCR.IBase())   ; GetSoftwareBitmapAsync
        OCR.WaitForAsync(&SoftwareBitmap)
        ComCall(6, OCR.OcrEngine, "ptr", SoftwareBitmap, "ptr*", OcrResult:=OCR.IBase())   ; RecognizeAsync
        OCR.WaitForAsync(&OcrResult)

        ; Cleanup
        Close := ComObjQuery(pIRandomAccessStream, IClosable := "{30D5A829-7FA4-4026-83BB-D75BAE4EA99E}")
        ComCall(6, Close)   ; Close
        Close := ComObjQuery(SoftwareBitmap, IClosable := "{30D5A829-7FA4-4026-83BB-D75BAE4EA99E}")
        ComCall(6, Close)   ; Close

        this.ptr := OcrResult.ptr, ObjAddRef(OcrResult.ptr)
    }
    __Delete() => this.ptr ? ObjRelease(this.ptr) : 0

    ; Gets the recognized text.
    Text {
        get {
            ComCall(8, this, "ptr*", &hAllText:=0)   ; get_Text
            buf := DllCall("Combase.dll\WindowsGetStringRawBuffer", "ptr", hAllText, "uint*", &length:=0, "ptr")
            this.DefineProp("Text", {Value:StrGet(buf, "UTF-16")})
            OCR.DeleteHString(hAllText)
            return this.Text
        }
    }

    ; Gets the clockwise rotation of the recognized text, in degrees, around the center of the image.
    TextAngle {
        get => (ComCall(7, this, "double*", &value:=0), value)
    }

    ; Returns all Line objects for the result.
    Lines {
        get {
            ComCall(6, this, "ptr*", LinesList:=OCR.IBase()) ; get_Lines
            ComCall(7, LinesList, "int*", &count:=0) ; count
            lines := []
            loop count {
                ComCall(6, LinesList, "int", A_Index-1, "ptr*", OcrLine:=OCR.OCRLine())               
                lines.Push(OcrLine)
            }
            this.DefineProp("Lines", {Value:lines})
            return lines
        }
    }

    ; Returns all Word objects for the result. Equivalent to looping over all the Lines and getting the Words.
    Words {
        get {
            words := []
            for line in this.Lines
                for word in line.Words
                    words.Push(word)
            this.DefineProp("Words", {Value:words})
            return words
        }
    }

    class OCRLine extends OCR.IBase {
        ; Gets the recognized text for the line.
        Text {
            get {
                ComCall(7, this, "ptr*", &hText:=0)   ; get_Text
                buf := DllCall("Combase.dll\WindowsGetStringRawBuffer", "ptr", hText, "uint*", &length:=0, "ptr")
                text := StrGet(buf, "UTF-16")
                OCR.DeleteHString(hText)
                this.DefineProp("Text", {Value:text})
                return text
            }
        }

        ; Gets the Word objects for the line
        Words {
            get {
                ComCall(6, this, "ptr*", WordsList:=OCR.IBase())   ; get_Words
                ComCall(7, WordsList, "int*", &WordsCount:=0)   ; Words count
                words := []
                loop WordsCount {
                   ComCall(6, WordsList, "int", A_Index-1, "ptr*", OcrWord:=OCR.OCRWord())
                   words.Push(OcrWord)
                }
                this.DefineProp("Words", {Value:words})
                return words
            }
        }
    }

    class OCRWord extends OCR.IBase {
        ; Gets the recognized text for the word
        Text {
            get {
                ComCall(7, this, "ptr*", &hText:=0)   ; get_Text
                buf := DllCall("Combase.dll\WindowsGetStringRawBuffer", "ptr", hText, "uint*", &length:=0, "ptr")
                text := StrGet(buf, "UTF-16")
                OCR.DeleteHString(hText)
                this.DefineProp("Text", {Value:text})
                return text
            }
        }

        /**
         * Gets the location of the text in {x,y,w,h} format. 
         * The location coordinate system will be dependant on the image capture method.
         * For example, if the image was captured as a rectangle from the screen, then the coordinates
         * will be relative to the left top corner of the rectangle.
         */
        Location {
            get {
                ComCall(6, this, "ptr", RECT := Buffer(16, 0))   ; get_BoundingRect
                return this.DefineProp("Location", {Value:{x:Integer(NumGet(RECT, 0, "float")), y:Integer(NumGet(RECT, 4, "float")), w:Integer(NumGet(RECT, 8, "float")), h:Integer(NumGet(RECT, 12, "float"))}}).Location
            }
        }
    }

    /**
     * Returns an OCR results object for an image file. Locations of the words will be relative to
     * the top left corner of the image.
     * @param FileName Either full or relative (to A_ScriptDir) path to the file.
     * @param lang OCR language. Default is first from available languages.
     * @returns {Ocr} 
     */
    static FromFile(FileName, lang?) {
        if (SubStr(FileName, 2, 1) != ":")
            FileName := A_ScriptDir "\" file
         if !FileExist(FileName) or InStr(FileExist(FileName), "D")
            throw TargetError("File `"" FileName "`" doesn't exist", -1)
         GUID := OCR.CLSIDFromString(OCR.IID_IRandomAccessStream)
         DllCall("ShCore\CreateRandomAccessStreamOnFile", "wstr", FileName, "uint", Read := 0, "ptr", GUID, "ptr*", IRandomAccessStream:=OCR.IBase())
         return OCR(IRandomAccessStream, lang?)
    }

    /**
     * Returns an OCR results object for a given window. Locations of the words will be relative to the
     * window or client area, so for interactions use CoordMode "Window" or "Client".
     * @param WinTitle A window title or other criteria identifying the target window.
     * @param lang OCR language. Default is first from available languages.
     * @param scale The scaling factor to use.
     * @param {Number} onlyClientArea Whether only the client area or the whole window should be OCR-d
     * @param {Number} mode Different methods of capturing the window. 0 = uses GetDC with BitBlt, 2 = uses PrintWindow. 
     * Add 1 to make a transparent window totally opaque. 
     * @returns {Ocr} 
     */
    static FromWindow(WinTitle:="", lang?, scale:=1, onlyClientArea:=0, mode:=2) {
        if !(hWnd := WinExist(WinTitle))
            throw TargetError("Target window not found", -1)
        if DllCall("IsIconic", "uptr", hwnd)
            DllCall("ShowWindow", "uptr", hwnd, "int", 4)
        if mode&1 {
            oldStyle := WinGetExStyle(hwnd), i := 0
            WinSetTransparent(255, hwnd)
            While (WinGetTransparent(hwnd) != 255 && ++i < 30)
                Sleep 100
        }
        If onlyClientArea {
            DllCall("GetClientRect", "ptr", hwnd, "ptr", rc:=Buffer(16))
            W := NumGet(rc, 8, "int"), H := NumGet(rc, 12, "int")
            pt:=Buffer(8, 0), NumPut("int64", 0, pt)
            DllCall("ClientToScreen", "Ptr", hwnd, "Ptr", pt)
            X:=NumGet(pt,"int"), Y:=NumGet(pt,4,"int")
        } else {
            rect := Buffer(16, 0)
            DllCall("GetWindowRect", "UPtr", hwnd, "Ptr", rect, "UInt")
            X := NumGet(rect, 0, "Int"), Y := NumGet(rect, 4, "Int")
            x2 := NumGet(rect, 8, "Int"), y2 := NumGet(rect, 12, "Int")
            W := Abs(Max(X, X2) - Min(X, X2))
            H := Abs(Max(Y, Y2) - Min(Y, Y2))
        }
        hBitMap := OCR.CreateBitmap(X, Y, W, H, hWnd, scale, onlyClientArea, mode)
        ;OCR.DisplayHBitmap(hBitMap)
        if mode&1
            WinSetExStyle(oldStyle, hwnd)
        result := OCR(OCR.HBitmapToRandomAccessStream(hBitMap), lang?)
        OCR.NormalizeCoordinates(result, scale)
        return result
    }

    /**
     * Returns an OCR results object for the whole desktop. Locations of the words will be relative to
     * the screen (CoordMode "Screen")
     * @param lang OCR language. Default is first from available languages.
     * @returns {Ocr} 
     */
    static FromDesktop(lang?, scale:=1) => OCR.FromRect(0, 0, A_ScreenWidth, A_ScreenHeight, lang?, scale)

    /**
     * Returns an OCR results object for a region of the screen. Locations of the words will be relative
     * to the top left corner of the rectangle.
     * @param x Screen x coordinate
     * @param y Screen y coordinate
     * @param w Region width
     * @param h Region height
     * @param lang OCR language. Default is first from available languages.
     * @param scale The scaling factor to use. Larger number (eg 2) might improve the accuracy
     *     of the OCR, at the cost of speed.
     * @returns {Ocr} 
     */
    static FromRect(x, y, w, h, lang?, scale:=1) {
        hBitmap := OCR.CreateBitmap(X, Y, W, H,,scale)
        ;OCR.DisplayHBitmap(hBitMap, W*scale, H*scale)
        return OCR.NormalizeCoordinates(OCR(OCR.HBitmapToRandomAccessStream(hBitmap), lang?), scale)
    }

    /**
     * Returns an OCR results object from a hBitmap object. Locations of the words will be relative
     * to the top left corner of the bitmap.
     * @param hBitmap An hBitmap pointer or an object with a ptr property
     * @param lang OCR language. Default is first from available languages.
     * @returns {ocr} 
     */
    static FromBitmap(hBitmap, lang?) => OCR(OCR.HBitmapToRandomAccessStream(hBitmap), lang?)

    /**
     * Returns all available languages as a string, where the languages are separated by newlines.
     * @returns {String} 
     */
    static GetAvailableLanguages() {
        static GlobalizationPreferencesStatics
        if !IsSet(GlobalizationPreferencesStatics)
            GlobalizationPreferencesStatics := OCR.CreateClass("Windows.System.UserProfile.GlobalizationPreferences", IGlobalizationPreferencesStatics := "{01BF4326-ED37-4E96-B0E9-C1340D1EA158}")
        ComCall(9, GlobalizationPreferencesStatics, "ptr*", &LanguageList:=0)   ; get_Languages
        ComCall(7, LanguageList, "int*", &count:=0)   ; count
        Loop count {
            ComCall(6, LanguageList, "int", A_Index-1, "ptr*", &hString:=0)   ; get_Item
            ComCall(6, this.LanguageFactory, "ptr", hString, "ptr*", &LanguageTest:=0)   ; CreateLanguage
            ComCall(8, this.OcrEngineStatics, "ptr", LanguageTest, "int*", &bool:=0)   ; IsLanguageSupported
            if (bool = 1) {
                ComCall(6, LanguageTest, "ptr*", &hText:=0)
                buf := DllCall("Combase.dll\WindowsGetStringRawBuffer", "ptr", hText, "uint*", &length:=0, "ptr")
                text .= StrGet(buf, "UTF-16") "`n"
            }
            ObjRelease(LanguageTest)
        }
        ObjRelease(LanguageList)
        return text
    }

    /**
     * Loads a new language which will be used with subsequent OCR calls.
     * @param {string} lang OCR language. Default is first from available languages.
     * @returns {void} 
     */
    static LoadLanguage(lang:="FirstFromAvailableLanguages") {
        if this.HasOwnProp("CurrentLanguage") && this.HasOwnProp("OcrEngine") && this.CurrentLanguage = lang
            return
        if (lang = "FirstFromAvailableLanguages")
            ComCall(10, this.OcrEngineStatics, "ptr*", OcrEngine:=OCR.IBase())   ; TryCreateFromUserProfileLanguages
        else {
            hString := OCR.CreateHString(lang)
            ComCall(6, this.LanguageFactory, "ptr", hString, "ptr*", Language:=OCR.IBase())   ; CreateLanguage
            OCR.DeleteHString(hString)
            ComCall(9, this.OcrEngineStatics, "ptr", Language, "ptr*", OcrEngine:=OCR.IBase())   ; TryCreateFromLanguage
        }
        if (OcrEngine.ptr = 0)
            Throw Error("Can not use language `"" lang "`" for OCR, please install language pack.")
        this.OcrEngine := OcrEngine, this.CurrentLanguage := lang
    }

    static CreateDIBSection(w, h, hdc?, bpp:=32, &ppvBits:=0) {
        hdc2 := IsSet(hdc) ? hdc : DllCall("GetDC", "Ptr", 0, "UPtr")
        bi := Buffer(40, 0)
        NumPut("int", 40, "int", w, "int", h, "ushort", 1, "ushort", bpp, "int", 0, bi)
        hbm := DllCall("CreateDIBSection", "uint", hdc2, "ptr" , bi, "uint" , 0, "uint*", &ppvBits:=0, "uint" , 0, "uint" , 0)
        if !IsSet(hdc)
            DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc2)
        return hbm
    }

    static CreateBitmap(X, Y, W, H, hWnd := 0, scale:=1, onlyClientArea:=0, mode:=2) {
        static CAPTUREBLT
        if !IsSet(CAPTUREBLT) {
            DllCall("Dwmapi\DwmIsCompositionEnabled", "Int*", &compositionEnabled:=0)
            CAPTUREBLT:= compositionEnabled ? 0 : 0x40000000
        }
        sW := W*scale, sH := H*scale
        if hWnd {
            if mode < 2 {
                X := 0, Y := 0
                HDC := DllCall("GetDCEx", "Ptr", hWnd, "Ptr", 0, "int", 2|!onlyClientArea, "Ptr")
            } else {
                hbm := OCR.CreateDIBSection(W, H)
                hdc := DllCall("CreateCompatibleDC", "Ptr", 0, "UPtr")
                obm := DllCall("SelectObject", "Ptr", HDC, "Ptr", HBM)
                DllCall("PrintWindow", "uint", hwnd, "uint", hdc, "uint", 2|!!onlyClientArea)
                if scale != 1 {
                    PDC := DllCall("CreateCompatibleDC", "Ptr", HDC, "UPtr")
                    hbm2 := DllCall("CreateCompatibleBitmap", "Ptr", HDC, "Int", sW, "Int", sH, "UPtr")
                    DllCall("SelectObject", "Ptr", PDC, "Ptr", HBM2)
                    DllCall("StretchBlt", "Ptr", PDC, "Int", 0, "Int", 0, "Int", sW, "Int", sH, "Ptr", HDC, "Int", 0, "Int", 0, "Int", W, "Int", H, "UInt", 0x00CC0020 | CAPTUREBLT) ; SRCCOPY
                    DllCall("DeleteDC", "Ptr", PDC)
                    DllCall("DeleteObject", "UPtr", HBM)
                    hbm := hbm2
                }
                DllCall("DeleteDC", "Ptr", HDC)
                return OCR.IBase(HBM).DefineProp("__Delete", {call:(*)=>DllCall("DeleteObject", "UPtr", HBM)})
            }
        } else {
            HDC := DllCall("GetDC", "Ptr", 0, "UPtr")
        }
        HBM := DllCall("CreateCompatibleBitmap", "Ptr", HDC, "Int", sW, "Int", sH, "UPtr")
        PDC := DllCall("CreateCompatibleDC", "Ptr", HDC, "UPtr")
        DllCall("SelectObject", "Ptr", PDC, "Ptr", HBM)
        DllCall("StretchBlt", "Ptr", PDC, "Int", 0, "Int", 0, "Int", sW, "Int", sH, "Ptr", HDC, "Int", X, "Int", Y, "Int", W, "Int", H, "UInt", 0x00CC0020 | CAPTUREBLT) ; SRCCOPY
        DllCall("DeleteDC", "Ptr", PDC)
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", HDC)
        return OCR.IBase(HBM).DefineProp("__Delete", {call:(*)=>DllCall("DeleteObject", "UPtr", HBM)})
    }

    static HBitmapToRandomAccessStream(hBitmap) {
        static PICTYPE_BITMAP := 1
             , BSOS_DEFAULT   := 0
             , sz := 8 + A_PtrSize*2
             
        DllCall("Ole32\CreateStreamOnHGlobal", "Ptr", 0, "UInt", true, "Ptr*", pIStream:=OCR.IBase(), "UInt")
        
        PICTDESC := Buffer(sz, 0)
        NumPut("uint", sz, "uint", PICTYPE_BITMAP, "ptr", IsInteger(hBitmap) ? hBitmap : hBitmap.ptr, PICTDESC)
        riid := OCR.CLSIDFromString(OCR.IID_IPicture)
        DllCall("OleAut32\OleCreatePictureIndirect", "Ptr", PICTDESC, "Ptr", riid, "UInt", 0, "Ptr*", pIPicture:=OCR.IBase(), "UInt")
        ; IPicture::SaveAsFile
        ComCall(15, pIPicture, "Ptr", pIStream, "UInt", true, "uint*", &size:=0, "UInt")
        riid := OCR.CLSIDFromString(OCR.IID_IRandomAccessStream)
        DllCall("ShCore\CreateRandomAccessStreamOverStream", "Ptr", pIStream, "UInt", BSOS_DEFAULT, "Ptr", riid, "Ptr*", pIRandomAccessStream:=OCR.IBase(), "UInt")
        Return pIRandomAccessStream
    }

    static DisplayHBitmap(hBitmap, W:=640, H:=640) {
        gImage := Gui()
        hPic := gImage.Add("Text", "0xE w" W " h" H)
        SendMessage(0x172, 0, hBitmap,, hPic.Hwnd)
        gImage.Show()
        WinWaitClose gImage
    }

    static CreateClass(str, interface) {
        hString := OCR.CreateHString(str)
        GUID := OCR.CLSIDFromString(interface)
        result := DllCall("Combase.dll\RoGetActivationFactory", "ptr", hString, "ptr", GUID, "ptr*", &cls:=0, "uint")
        if (result != 0) {
            if (result = 0x80004002)
                throw Error("No such interface supported", -1, interface)
            else if (result = 0x80040154)
                throw Error("Class not registered", -1)
            else
                throw Error(result)
        }
        OCR.DeleteHString(hString)
        return cls
    }
    
    static CreateHString(str) => (DllCall("Combase.dll\WindowsCreateString", "wstr", str, "uint", StrLen(str), "ptr*", &hString:=0), hString)
    
    static DeleteHString(hString) => DllCall("Combase.dll\WindowsDeleteString", "ptr", hString)
    
    static WaitForAsync(&obj) {
        AsyncInfo := ComObjQuery(obj, OCR.IID_IAsyncInfo)
        Loop {
            ComCall(7, AsyncInfo, "uint*", &status:=0)   ; IAsyncInfo.Status
            if (status != 0) {
                if (status != 1) {
                    ComCall(8, ASyncInfo, "uint*", &ErrorCode:=0)   ; IAsyncInfo.ErrorCode
                    throw Error("AsyncInfo failed with status error " ErrorCode, -1)
                }
             break
          }
          Sleep 10
        }
        ComCall(8, obj, "ptr*", ObjectResult:=OCR.IBase())   ; GetResults
        obj := ObjectResult
    }

    static CLSIDFromString(IID) {
        CLSID := Buffer(16)
        if res := DllCall("ole32\CLSIDFromString", "WStr", IID, "Ptr", CLSID, "UInt")
           throw Error("CLSIDFromString failed. Error: " . Format("{:#x}", res))
        Return CLSID
    }

    static NormalizeCoordinates(result, scale) {
        if scale != 1 {
            for word in result.Words
                loc := word.Location, loc.x := Integer(loc.x / scale), loc.y := Integer(loc.y / scale), loc.w := Integer(loc.w / scale), loc.h := Integer(loc.h / scale)
        }
        return result
    }
}