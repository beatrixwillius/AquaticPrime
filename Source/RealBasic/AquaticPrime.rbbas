#tag Class
Class AquaticPrime
	#tag Method, Flags = &h0
		Sub AddToBlacklist(newHash as string)
		  
		  mblacklist.append newHash
		  
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub Constructor()
		  // use the other one!
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub Constructor(publicKey as string, privateKey as string = "")
		  
		  #if targetMacOS or targetLinux
		    
		    Declare Sub ERR_load_crypto_strings Lib CryptoLib ()
		    
		    ERR_load_crypto_strings
		    
		  #endif
		  
		  self.SetKey publicKey, privateKey
		  
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h1
		Protected Sub Destructor()
		  
		  #if targetMacOS or targetLinux
		    
		    Declare Sub ERR_free_strings Lib CryptoLib ()
		    Declare Sub RSA_free Lib CryptoLib (r as Ptr)
		    
		    ERR_free_strings
		    
		    if rsaKey <> nil then
		      RSA_free(rsaKey)
		    end if
		    
		  #elseif TargetWin32
		    
		    Declare Function CryptReleaseContext Lib advapi (hProv As Integer, dwFlags As Integer) As Boolean
		    Declare Function CryptDestroyKey Lib advapi (hKey As Integer) As Boolean
		    
		    if winKeyHdl <> 0 then
		      call CryptDestroyKey (winKeyHdl)
		      winKeyHdl = 0
		    end if
		    
		    if winCtx <> 0 then
		      call CryptReleaseContext (winCtx, 0)
		      winCtx = 0
		    end if
		    
		  #endif
		  
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function DictionaryForLicenseData(licenseData as string) As dictionary
		  #pragma DisableBackgroundTasks // we don't want any interruptions here
		  
		  #if targetMacOS or targetLinux
		    Declare Function RSA_public_decrypt Lib CryptoLib (flen as integer, from as Ptr, mto as Ptr, rsa as Ptr, padding as integer) As integer
		    Declare Function ERR_error_string Lib CryptoLib (e as UInt32, buf as Ptr) As CString
		    Declare Function ERR_get_error Lib CryptoLib () As UInt32
		    Declare Function SHA1_Init Lib CryptoLib (c as Ptr) As integer
		    Declare Function SHA1_Update Lib CryptoLib (c as Ptr, data as CString, mlen as UInt32) As integer
		    Declare Function SHA1_Final Lib CryptoLib (md as Ptr, c as Ptr) As integer
		  #endif
		  
		  dim x as new xmlDocument
		  dim topDoc as xmlElement
		  dim dict as xmlElement
		  dim keyArray(-1) as string
		  dim valueArray(-1) as string
		  dim node as XMLNode
		  dim element as XMLElement
		  dim n as integer
		  dim sigBytes as MemoryBlock
		  
		  const kLicenseDataNotValidError = "Invalid license data"
		  
		  // Make sure public key is set up
		  if TargetWin32 and winKeyHdl = 0 or not TargetWin32 and (rsaKey = nil or rsaKey.UInt32Value(16) = 0) then
		    _setError "RSA key is invalid"
		    return nil
		  end if
		  
		  // Traverse the XML structure and load key-value pairs in arrays
		  try
		    x.loadXml(licenseData)
		    
		    // Do some sanity checks on the XML
		    if x.documentElement is nil or x.documentElement.childCount <> 1 then
		      _setError kLicenseDataNotValidError
		      return nil
		    end if
		    
		    topDoc = x.documentElement
		    if topDoc.LocalName <> "plist" or topDoc.firstChild is nil or not topDoc.firstChild isA XMLElement then
		      _setError kLicenseDataNotValidError
		      return nil
		    end if
		    
		    dict = XMLElement(topDoc.firstChild)
		    if dict.LocalName <> "dict" or dict.childCount = 0 then
		      _setError kLicenseDataNotValidError
		      return nil
		    end if
		    
		    node = dict.firstChild
		    
		    do
		      if not node isA XMLElement then
		        return nil
		      end if
		      element = XMLElement(node)
		      if element.childCount <> 1 or not element.firstChild isA XMLTextNode then
		        _setError kLicenseDataNotValidError
		        return nil
		      end if
		      
		      if element.LocalName = "key" then
		        keyArray.append element.firstChild.value
		      elseif element.LocalName = "string" or element.LocalName = "data" then
		        valueArray.append element.firstChild.value
		      end if
		      node = element.nextSibling
		    loop until node is nil
		    
		    // Get the signature
		    sigBytes = DecodeBase64(valueArray(keyArray.indexOf("Signature")))
		    
		    // Remove the Signature element from arrays
		    dim elementNumber as integer= keyArray.indexOf("Signature")
		    keyArray.remove elementNumber
		    valueArray.remove elementNumber
		    
		    // Sort the keys because that's important for the SHA1 calculation
		    //
		    // Ideally, this should use the same ordering that the Cocoa and CF
		    // sources use (i.e. "case insensitive", but it's not clear which chars
		    // are considered for this case test - all letters of all encodings and
		    // scripts, or only ASCII?)
		    //
		    keyArray.sortWith(valueArray)
		    
		  catch err as RuntimeException
		    _setError kLicenseDataNotValidError
		    return nil
		  end try
		  
		  // Get the SHA1 hash digest from the license data and verify the signature with it
		  dim digest as new MemoryBlock(SHA_DIGEST_LENGTH)
		  #if targetMacOS or targetLinux
		    
		    // Calculate the digest
		    dim ctx as new memoryBlock(96)
		    call SHA1_Init(ctx)
		    for i as integer = 0 to valueArray.Ubound
		      call SHA1_Update(ctx, valueArray(i), lenB(valueArray(i)))
		    next
		    call SHA1_Final(digest, ctx)
		    
		    // Get the signature's hash
		    dim sigDigest as new MemoryBlock(SHA_DIGEST_LENGTH)
		    if RSA_public_decrypt(sigBytes.Size, sigBytes, sigDigest, rsaKey, RSA_PKCS1_PADDING) <> SHA_DIGEST_LENGTH then
		      _setError ERR_error_string(ERR_get_error(), nil)
		      return nil
		    end if
		    
		    // Check if the signature's hash is a match
		    if StrComp (sigDigest, digest, 0) <> 0 then
		      return nil
		    end if
		    
		  #elseif TargetWin32
		    // On Windows, I can't find a way to retrieve the hash from the signature. All I find is a verify function that takes a hash and checks
		    // that against the signature. Therefore, we'll now calculate the hash of the license data and let the Windows function verify
		    // it. If it's valid, it can be used for the blacklist check just as well.
		    
		    Declare Function CryptCreateHash Lib advapi (hProv As Integer, Algid As Integer, hKey As Integer, dwFlags As Integer, ByRef phHash As Integer) As Boolean
		    Declare Function CryptHashData Lib advapi (hHash As Integer, pbData As CString, dwDataLen As Integer, dwFlags As Integer) As Boolean
		    Declare Function CryptDestroyHash Lib advapi (hHash As Integer) As Boolean
		    Declare Function CryptGetHashParam Lib advapi (hHash As Integer, type as Integer, data as Ptr, ByRef dlen as Integer, flags as Integer) As Boolean
		    Declare Function GetLastError Lib kernel () As Integer
		    Declare Function CryptVerifySignature Lib advapi Alias "CryptVerifySignatureA" (hHash As Integer, pbSignature As Ptr, dwSigLen As Integer, hPubKey As Integer, sDescription As Ptr, dwFlags As Integer) As Boolean
		    Const HP_HASHVAL = 2
		    Const CALG_SHA1 = &h00008004
		    Const NTE_BAD_SIGNATURE = &h80090006
		    
		    dim hashHdl as Integer
		    call CryptCreateHash (winCtx, CALG_SHA1, 0, 0, hashHdl)
		    for i as integer = 0 to valueArray.Ubound
		      call CryptHashData (hashHdl, valueArray(i), lenB(valueArray(i)), 0)
		    next
		    
		    sigBytes = _reverseData(sigBytes)
		    
		    if not CryptVerifySignature (hashHdl, sigBytes, sigBytes.Size, winKeyHdl, nil, 0) then
		      dim res as Integer = GetLastError()
		      if res = NTE_BAD_SIGNATURE then
		        _setError "Bad signature"
		      else
		        _setError _errorMsgFromCode (res)
		      end
		      call CryptDestroyHash (hashHdl)
		      return nil
		    end if
		    
		    dim dlen as Integer = digest.Size
		    call CryptGetHashParam (hashHdl, HP_HASHVAL, digest, dlen, 0)
		    call CryptDestroyHash (hashHdl)
		    
		  #endif
		  
		  // Get the textual represenation of the license hash and store it in case we need it later
		  n = SHA_DIGEST_LENGTH-1
		  dim hashCheck as string
		  for hashIndex as integer = 0 to n
		    hashCheck = hashCheck + lowercase(right("0"+hex(digest.byte(hashIndex)), 2))
		  next
		  mHash = hashCheck
		  
		  // Make sure the license hash isn't on the blacklist
		  if mblacklist.indexOf(hash) >= 0 then
		    return nil
		  end if
		  
		  // Build a RB dictionary to return
		  dim retDict as new dictionary
		  for i as integer = 0 to keyArray.Ubound
		    retDict.value(keyArray(i)) = valueArray(i)
		  next
		  
		  return retDict
		  
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function DictionaryForLicenseFile(licenseFile as folderItem) As dictionary
		  
		  // Read the XML file
		  dim licenseStream as binaryStream
		  dim data as string
		  
		  if licenseFile = nil or not licenseFile.exists or not licenseFile.isReadable then
		    return nil
		  end if
		  
		  licenseStream = BinaryStream.Open(licenseFile)
		  if licenseStream = nil then
		    return nil
		  end if
		  
		  data = licenseStream.read(licenseStream.length)
		  licenseStream.close
		  
		  return DictionaryForLicenseData(data)
		  
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function LicenseDataForDictionary(dict as dictionary) As string
		  #if targetMacOS or targetLinux
		    Declare Function SHA1 Lib CryptoLib (d as Ptr, n as UInt32, md as Ptr) As Ptr
		    Declare Function RSA_size Lib CryptoLib (RSA as Ptr) as Integer
		    Declare Function RSA_private_encrypt Lib CryptoLib (flen as Integer, from as Ptr, mto as Ptr, rsa as Ptr, padding as integer) as integer
		    Declare Function ERR_error_string Lib CryptoLib (e as UInt32, buf as Ptr) As CString
		    Declare Function ERR_get_error Lib CryptoLib () As UInt32
		  #else
		    // Support for other platforms, i.e. Windows, hasn't been implemented yet
		    raise new RuntimeException
		  #endif
		  
		  // Make sure we have a good key
		  if rsaKey = nil or rsaKey.UInt32Value(16) = 0 or rsaKey.UInt32Value(24) = 0 then
		    _setError "RSA key is invalid"
		    return ""
		  end if
		  
		  // Grab all values from the dictionary
		  dim keyArray(-1) as string
		  dim dictData as new memoryBlock(1)
		  dim n as integer = dict.count-1
		  for i as integer = 0 to n
		    keyArray.append dict.key(i)
		  next
		  
		  // Sort the keys so we always have a uniform order
		  keyArray.Sort
		  dim oldSize as integer = 0
		  for i as integer = 0 to n
		    dim curValue as string = dict.value(keyArray(i))
		    dictData.size = oldSize+lenB(curValue)
		    dictData.StringValue(oldSize, lenB(curValue)) = curValue
		    oldSize = dictData.size
		  next
		  
		  // Hash the data
		  #if targetMacOS or targetLinux
		    dim digest as new memoryBlock(20)
		    call SHA1(dictData, dictData.size, digest)
		  #endif
		  
		  // Create the signature from 20 byte hash
		  dim bytes as integer
		  dim signature as memoryBlock
		  #if targetMacOS or targetLinux
		    dim rsaLength as integer = RSA_size(rsaKey)
		    signature = new memoryBlock(rsaLength)
		    bytes = RSA_private_encrypt(20, digest, signature, rsaKey, RSA_PKCS1_PADDING)
		  #endif
		  
		  if bytes = -1 then
		    #if targetMacOS or targetLinux
		      _setError ERR_error_string(ERR_get_error(), nil)
		    #endif
		    return ""
		  end if
		  
		  // Create plist data (XML document)
		  dim x as new XMLDocument
		  dim comment as XMLComment= x.createComment("DOCTYPE plist PUBLIC ""-//Apple//DTD PLIST 1.0//EN"" ""http://www.apple.com/DTDs/PropertyList-1.0.dtd""")
		  x.appendChild comment
		  dim plist as XMLNode = x.appendChild(x.createElement("plist"))
		  dim attr as XMLAttribute = x.createAttribute("version")
		  attr.value = "1.0"
		  plist.setAttributeNode(attr)
		  dim dictXML as XMLNode = plist.appendChild(x.createElement("dict"))
		  
		  n = ubound(keyArray)
		  for i as integer = 0 to n
		    dim key as XMLNode = dictXML.appendChild(x.createElement("key"))
		    key.appendChild x.createTextNode(keyArray(i))
		    dim value as XMLNode = dictXML.appendChild(x.createElement("string"))
		    value.appendChild x.createTextNode(dict.value(keyArray(i)))
		  next
		  
		  dim key as XMLNode = dictXML.appendChild(x.createElement("key"))
		  key.appendChild x.createTextNode("Signature")
		  dim value as XMLNode = dictXML.appendChild(x.createElement("data"))
		  value.appendChild x.createTextNode(ReplaceLineEndings(EncodeBase64(signature.stringValue(0, bytes), 68), endOfLine.UNIX))
		  
		  // Reformat XML for pretty printing
		  dim XMLoutput as string = ReplaceAll(x.toString, "><", ">"+endOfLine.UNIX+"<")
		  XMLoutput = Replace(Replace(XMLoutput, "<!--", "<!"), "-->", ">")
		  XMLoutput = ReplaceAll(XMLoutput, "<key>", chr(9)+"<key>")
		  XMLoutput = ReplaceAll(XMLoutput, "<string>", chr(9)+"<string>")
		  XMLoutput = ReplaceAll(XMLoutput, "<data>", chr(9)+"<data>"+endOfLine.UNIX)
		  XMLoutput = Replace(XMLoutput, "</data>", endOfLine.UNIX+chr(9)+"</data>")
		  dim dataStart as integer = instr(XMLoutput, "<data>")+6
		  dim dataEnd as integer = instr(XMLoutput, "="+endOfLine.UNIX)-2
		  XMLoutput = left(XMLoutput, dataStart-1)_
		  +replaceAll(mid(XMLoutput, dataStart, dataEnd-dataStart), endOfLine.UNIX, endOfLine.UNIX+chr(9))_
		  +mid(XMLoutput, dataEnd)_
		  +endOfLine.UNIX
		  
		  return XMLoutput
		  
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub SetBlacklist(hashArray() as string)
		  
		  dim u as Integer = UBound(hashArray)
		  redim mblacklist(u)
		  
		  for i as Integer = 0 to u
		    mblacklist(i) = hashArray(i)
		  next
		  
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub SetKey(key as string, privateKey as string = "")
		  
		  dim result as integer, ok as Boolean
		  
		  // Must have public modulus, private key is optional
		  if key = "" then
		    _setError "Empty public key parameter"
		    return
		  end if
		  
		  #if targetMacOS or targetLinux
		    Declare Sub RSA_free Lib CryptoLib (r as Ptr)
		    Declare Function RSA_new Lib CryptoLib () As Ptr
		    Declare Function BN_dec2bn Lib CryptoLib (a as UInt32, str as CString) As integer
		    Declare Function BN_hex2bn Lib CryptoLib (a as UInt32, str as CString) As integer
		    Declare Function ERR_get_error Lib CryptoLib () As UInt32
		    Declare Function ERR_error_string Lib CryptoLib (e as UInt32, buf as Ptr) As CString
		    
		    if rsaKey <> nil then
		      RSA_free(rsaKey)
		    end if
		    rsaKey = RSA_new()
		    
		    // We are using the constant public exponent e = 3
		    call BN_dec2bn(_ptrToInt(rsaKey)+20, "3")
		    
		    // Determine if we have hex or decimal values
		    if left(key, 2) = "0x" then
		      result = BN_hex2bn(_ptrToInt(rsaKey)+16, mid(key, 3))
		    else
		      result = BN_dec2bn(_ptrToInt(rsaKey)+16, key)
		    end if
		    
		    if result = 0 then
		      _setError ERR_error_string(ERR_get_error(), nil)
		      return
		    end if
		    
		    // Do the private portion if it exists
		    if privateKey <> "" then
		      if left(privateKey, 2) = "0x" then
		        result = BN_hex2bn(_ptrToInt(rsaKey)+24, mid(privateKey, 3))
		      else
		        result = BN_dec2bn(_ptrToInt(rsaKey)+24, privateKey)
		      end if
		      
		      if result = 0 then
		        _setError ERR_error_string(ERR_get_error(), nil)
		        return
		      end if
		    end if
		    
		  #elseif TargetWin32
		    Declare Function CryptReleaseContext Lib advapi (hProv As Integer, dwFlags As Integer) As Boolean
		    Declare Function CryptImportKey Lib advapi (hProv As Integer, data As Ptr, dlen As Integer, pbData As Ptr, flags as Integer, ByRef keyHandleOut As Integer) As Boolean
		    Declare Function CryptDestroyKey Lib advapi (hKey As Integer) As Boolean
		    Declare Function GetLastError Lib kernel () As Integer
		    Const PROV_RSA_FULL = 1
		    Const MS_DEF_PROV = "Microsoft Base Cryptographic Provider v1.0"
		    Const MS_ENHANCED_PROV = "Microsoft Enhanced Cryptographic Provider v1.0"
		    Const CRYPT_VERIFYCONTEXT = &hF0000000
		    
		    if privateKey <> "" then
		      // we're not supporting this (yet), because it requires a different CryptAcquireContext call and also more code in the other functions
		      _setError "Key generation not support on Windows"
		      return
		    end if
		    
		    if winKeyHdl <> 0 then
		      call CryptDestroyKey (winKeyHdl)
		      winKeyHdl = 0
		    end if
		    
		    dim pubKeyData as MemoryBlock = _decodeHexDigits (key) // this is usually 128 bytes in length
		    pubKeyData = _reverseData(pubKeyData)
		    
		    // set up data for CryptImportKey, see http://msdn.microsoft.com/en-us/library/aa387459(v=VS.85).aspx ("Public Key BLOBs")
		    dim blob as new MemoryBlock (20+pubKeyData.Size) // a PUBLICKEYSTRUC, specifically a PUBLICKEYBLOB plus key data
		    blob.UInt32Value(0) = &h00000206
		    blob.UInt32Value(4) = &h0000A400
		    blob.UInt32Value(8) = &h31415352 // 'RSA1'
		    blob.UInt32Value(12) = pubKeyData.Size * 8
		    blob.UInt32Value(16) = 3 // the public exponent
		    blob.StringValue(20,pubKeyData.Size) = pubKeyData
		    
		    dim rsaContext as Integer = winCtx
		    if rsaContext <> 0 then
		      ok = true
		    else
		      #if false
		        // This creates a new keyset as needed for for encryption:
		        Declare Function CryptAcquireContext Lib advapi Alias "CryptAcquireContextA" (ByRef phProv As Integer, pszContainer As Ptr, pszProvider As CString, dwProvType As Integer, dwFlags As Integer) As Boolean
		        ok = CryptAcquireContext (rsaContext, nil, MS_ENHANCED_PROV, PROV_RSA_FULL, 0)
		        if not ok then
		          result = GetLastError() // careful -- you won't get the right code here if you step here in the debugger, as the debugger clears this error code!
		          if result = &h80090016 then // NTE_BAD_KEYSET
		            ok = CryptAcquireContext (rsaContext, nil, MS_ENHANCED_PROV, PROV_RSA_FULL, 8) // create new one
		          end if
		        end
		      #else
		        // This creates a temporary keyset for verification only:
		        Declare Function CryptAcquireContext Lib advapi Alias "CryptAcquireContextA" (ByRef phProv As Integer, pszContainer As Ptr, pszProvider As Ptr, dwProvType As Integer, dwFlags As Integer) As Boolean
		        ok = CryptAcquireContext (rsaContext, nil, nil, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT)
		      #endif
		    end if
		    if not ok then
		      _setError _errorMsgFromLastError
		      break
		    else
		      winCtx = rsaContext
		      dim keyHdl as Integer
		      ok = CryptImportKey (rsaContext, blob, blob.Size, nil, 0, keyHdl)
		      if not ok then
		        _setError _errorMsgFromLastError
		        break
		      else
		        winKeyHdl = keyHdl
		      end
		    end if
		  #endif
		  
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function VerifyLicenseData(data as string) As boolean
		  
		  return (self.DictionaryForLicenseData(data) <> nil)
		  
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function VerifyLicenseFile(file as folderItem) As boolean
		  
		  return (self.DictionaryForLicenseFile(file) <> nil)
		  
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function WriteLicenseFileForDictionary(dict as dictionary, file as folderItem) As boolean
		  
		  dim licenseFile as string = self.LicenseDataForDictionary(dict)
		  
		  if licenseFile = "" then
		    return false
		  end if
		  
		  if file = nil or not file.isWriteable then
		    return false
		  end if
		  
		  dim licenseStream as BinaryStream = BinaryStream.Create(file, true)
		  if licenseStream = nil then
		    return false
		  end if
		  
		  licenseStream.write(licenseFile)
		  licenseStream.close
		  
		  return true
		  
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Shared Function _decodeHexDigits(hexText as String) As MemoryBlock
		  #if TargetWin32
		    dim startOfs as Integer
		    if hexText.Left(2) = "0x" then
		      startOfs = 2
		    end
		    dim output as new MemoryBlock((hexText.Len-startOfs)\2)
		    for i as Integer = 1 to hexText.Len-startOfs step 2
		      dim s as String = hexText.Mid(i+startOfs,2)
		      output.UInt8Value((i-1)\2) = Val("&h"+s)
		    next
		    return output
		  #endif
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Shared Function _errorMsgFromCode(code as Integer) As String
		  #if TargetWin32
		    // for error code meanings, see: http://msdn.microsoft.com/en-us/library/cc704587(PROT.10).aspx
		    
		    Declare Function FormatMessage Lib kernel Alias "FormatMessageA" (dwFlags As Integer, lpSource As Integer, dwMessageId As Integer, dwLanguageId As Integer, lpBuffer As Ptr, nSize As Integer, Arguments As Ptr) As Integer
		    const FORMAT_MESSAGE_FROM_SYSTEM = &h00001000
		    dim msg as new MemoryBlock(1024)
		    dim n as Integer = FormatMessage (FORMAT_MESSAGE_FROM_SYSTEM, 0, code, 0, msg, msg.Size, nil)
		    if n = n then
		      return "ErrorCode="+Right("0000000"+Hex(code),8)
		    end
		    dim s as String = msg.StringValue(0,n)
		    return s.DefineEncoding(Encodings.SystemDefault) // Not sure about the encoding here, though! Does someone know? Please fix and update in git!
		  #endif
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Shared Function _errorMsgFromLastError() As String
		  #if TargetWin32
		    Declare Function GetLastError Lib kernel () As Integer
		    dim code as Integer = GetLastError()
		    return _errorMsgFromCode (code)
		  #endif
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Shared Function _ptrToInt(m as memoryBlock) As UInt32
		  dim mAddr as new memoryBlock(4)
		  mAddr.ptr(0) = m
		  return mAddr.UInt32Value(0)
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Shared Function _reverseData(mb as MemoryBlock) As MemoryBlock
		  dim d2 as new MemoryBlock(mb.Size)
		  for i as integer = 0 to mb.Size-1
		    d2.Byte(mb.Size-1-i) = mb.Byte(i)
		  next
		  return d2
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub _setError(err as string)
		  
		  aqError = err
		  
		End Sub
	#tag EndMethod


	#tag Note, Name = Legal
		
		AquaticPrime.rbp
		AquaticPrime REAL Studio (REALbasic) Implementation
		
		Copyright (c) 2010, Massimo Valle
		All rights reserved.
		
		derived and adapted from the original C/Objective-C impementation
		Copyright (c) 2005, Lucas Newman
		All rights reserved.
		
		Redistribution and use in source and binary forms, with or without modification,
		are permitted provided that the following conditions are met:
		- Redistributions of source code must retain the above copyright notice,
		this list of conditions and the following disclaimer.
		- Redistributions in binary form must reproduce the above copyright notice,
		this list of conditions and the following disclaimer in the documentation and/or
		other materials provided with the distribution.
		- Neither the name of the Aquatic nor the names of its contributors may be used to
		endorse or promote products derived from this software without specific prior written permission.
		
		THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
		IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
		FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
		CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
		DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
		DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER
		IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT
		OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
	#tag EndNote

	#tag Note, Name = Windows support
		While the code should be complete for use with OSX and Linux,
		the Windows code is currently only supporting verification
		of a signed license, but not creating new ones.
	#tag EndNote


	#tag Property, Flags = &h21
		Private aqError As string
	#tag EndProperty

	#tag ComputedProperty, Flags = &h0
		#tag Getter
			Get
			  
			  return mHash
			End Get
		#tag EndGetter
		Hash As string
	#tag EndComputedProperty

	#tag ComputedProperty, Flags = &h0
		#tag Getter
			Get
			  
			  #if targetMacOS
			    
			    Declare Function BN_bn2hex Lib CryptoLib (a as UInt32) As CString
			    
			    if rsaKey = nil or rsaKey.UInt32Value(16) = 0 then
			      return ""
			    end if
			    
			    return BN_bn2hex(_ptrToInt(rsaKey)+16)
			    
			  #endif
			End Get
		#tag EndGetter
		Key As string
	#tag EndComputedProperty

	#tag ComputedProperty, Flags = &h0
		#tag Getter
			Get
			  
			  return aqError
			  
			End Get
		#tag EndGetter
		LastError As string
	#tag EndComputedProperty

	#tag Property, Flags = &h21
		Private mblacklist() As string
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mHash As string
	#tag EndProperty

	#tag ComputedProperty, Flags = &h0
		#tag Getter
			Get
			  
			  #if targetMacOS
			    
			    Declare Function BN_bn2hex Lib CryptoLib (a as UInt32) As CString
			    
			    if rsaKey = nil or rsaKey.UInt32Value(24) = 0 then
			      return ""
			    end if
			    
			    return BN_bn2hex(_ptrToInt(rsaKey)+24)
			    
			  #endif
			End Get
		#tag EndGetter
		PrivateKey As string
	#tag EndComputedProperty

	#tag Property, Flags = &h21
		Private rsaKey As memoryBlock
	#tag EndProperty

	#tag Property, Flags = &h21
		Private winCtx As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private winKeyHdl As Integer
	#tag EndProperty


	#tag Constant, Name = advapi, Type = String, Dynamic = False, Default = \"advapi32.dll", Scope = Private
	#tag EndConstant

	#tag Constant, Name = CryptoLib, Type = String, Dynamic = False, Default = \"/usr/lib/libcrypto.dylib", Scope = Private
		#Tag Instance, Platform = Linux, Language = Default, Definition  = \"libcrypto"
	#tag EndConstant

	#tag Constant, Name = kernel, Type = String, Dynamic = False, Default = \"kernel32.dll", Scope = Private
	#tag EndConstant

	#tag Constant, Name = RSA_PKCS1_PADDING, Type = Double, Dynamic = False, Default = \"1", Scope = Private
	#tag EndConstant

	#tag Constant, Name = SHA_DIGEST_LENGTH, Type = Double, Dynamic = False, Default = \"20", Scope = Private
	#tag EndConstant


	#tag ViewBehavior
		#tag ViewProperty
			Name="hash"
			Group="Behavior"
			Type="string"
			EditorType="MultiLineEditor"
		#tag EndViewProperty
		#tag ViewProperty
			Name="Index"
			Visible=true
			Group="ID"
			InitialValue="-2147483648"
			InheritedFrom="Object"
		#tag EndViewProperty
		#tag ViewProperty
			Name="Key"
			Group="Behavior"
			Type="string"
			EditorType="MultiLineEditor"
		#tag EndViewProperty
		#tag ViewProperty
			Name="LastError"
			Group="Behavior"
			Type="string"
			EditorType="MultiLineEditor"
		#tag EndViewProperty
		#tag ViewProperty
			Name="Left"
			Visible=true
			Group="Position"
			InitialValue="0"
			InheritedFrom="Object"
		#tag EndViewProperty
		#tag ViewProperty
			Name="Name"
			Visible=true
			Group="ID"
			InheritedFrom="Object"
		#tag EndViewProperty
		#tag ViewProperty
			Name="PrivateKey"
			Group="Behavior"
			Type="string"
			EditorType="MultiLineEditor"
		#tag EndViewProperty
		#tag ViewProperty
			Name="Super"
			Visible=true
			Group="ID"
			InheritedFrom="Object"
		#tag EndViewProperty
		#tag ViewProperty
			Name="Top"
			Visible=true
			Group="Position"
			InitialValue="0"
			InheritedFrom="Object"
		#tag EndViewProperty
	#tag EndViewBehavior
End Class
#tag EndClass
