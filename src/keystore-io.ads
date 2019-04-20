-----------------------------------------------------------------------
--  keystore-io -- IO low level operation for the keystore
--  Copyright (C) 2019 Stephane Carrez
--  Written by Stephane Carrez (Stephane.Carrez@gmail.com)
--
--  Licensed under the Apache License, Version 2.0 (the "License");
--  you may not use this file except in compliance with the License.
--  You may obtain a copy of the License at
--
--      http://www.apache.org/licenses/LICENSE-2.0
--
--  Unless required by applicable law or agreed to in writing, software
--  distributed under the License is distributed on an "AS IS" BASIS,
--  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
--  See the License for the specific language governing permissions and
--  limitations under the License.
-----------------------------------------------------------------------
with Ada.Streams;
with Ada.Calendar;
with Interfaces;
with Util.Encoders.AES;
private package Keystore.IO is

   use Ada.Streams;

   --  Data block size defined to a 4K to map system page.
   Block_Size           : constant := 4096;

   BT_HMAC_HEADER_SIZE  : constant := 32;
   BT_TYPE_HEADER_SIZE  : constant := 16;

   --  Block type magic values.
   BT_WALLET_UNUSED     : constant := 16#00000000#;
   BT_WALLET_HEADER     : constant := 16#01010101#;
   BT_WALLET_REPOSITORY : constant := 16#02020202#;
   BT_WALLET_DATA       : constant := 16#03030303#;

   subtype Block_Index is Stream_Element_Offset range 1 .. Block_Size;

   subtype Block_Type is Stream_Element_Array (Block_Index);

   BT_HEADER_START : constant Block_Index := Block_Index'First + BT_HMAC_HEADER_SIZE;
   BT_DATA_START   : constant Block_Index := BT_HEADER_START + BT_TYPE_HEADER_SIZE;
   BT_DATA_LENGTH  : constant Block_Index := Block_Index'Last - BT_DATA_START + 1;

   type Block_Count is new Natural;

   subtype Block_Number is Block_Count range 1 .. Block_Count'Last;

   type Marshaller;

   type Wallet_Stream is synchronized interface;

   --  Returns true if the block number is allocated.
   function Is_Used (Stream : in Wallet_Stream;
                     Block  : in Block_Number) return Boolean is abstract;

   --  Read from the wallet stream the block identified by the number and
   --  call the `Process` procedure with the data block content.
   procedure Read (Stream  : in out Wallet_Stream;
                   Block   : in Block_Number;
                   Process : not null access
                     procedure (Data : in Block_Type)) is abstract;

   --  Write in the wallet stream the block identified by the block number.
   procedure Write (Stream  : in out Wallet_Stream;
                    Block   : in Block_Number;
                    Process : not null access
                      procedure (Data : out Block_Type)) is abstract;

   --  Allocate a new block and return the block number in `Block`.
   procedure Allocate (Stream : in out Wallet_Stream;
                       Block  : out Block_Number) is abstract;

   --  Release the block number.
   procedure Release (Stream : in out Wallet_Stream;
                      Block  : in Block_Number) is abstract;

   --  Read the block from the wallet IO stream and decrypt the block content using
   --  the decipher object.  The decrypted content is stored in the marshaller which
   --  is ready to read the start of the block header.
   procedure Read (Stream       : in out Wallet_Stream'Class;
                   Block        : in Block_Number;
                   Decrypt_Size : in Block_Index := BT_DATA_LENGTH;
                   Decipher     : in out Util.Encoders.AES.Decoder;
                   Sign         : in Stream_Element_Array;
                   Into         : in out Marshaller) with
     Pre => Decrypt_Size mod 16 = 0 and Decrypt_Size <= BT_DATA_LENGTH;

   --  Write the block in the wallet IO stream.  Encrypt the block data using the
   --  cipher object.  Sign the header and encrypted data using HMAC-256 and the
   --  given signature.
   procedure Write (Stream       : in out Wallet_Stream'Class;
                    Block        : in Block_Number;
                    Encrypt_Size : in Block_Index := BT_DATA_LENGTH;
                    Cipher       : in out Util.Encoders.AES.Encoder;
                    Sign         : in Stream_Element_Array;
                    From         : in Marshaller) with
     Pre => Encrypt_Size mod 16 = 0 and Encrypt_Size <= BT_DATA_LENGTH;

   type Marshaller is limited record
      Data : Block_Type;
      Pos  : Block_Index := Block_Type'First;
   end record;

   --  Set the block header with the tag and wallet identifier.
   procedure Set_Header (Into : in out Marshaller;
                         Tag  : in Interfaces.Unsigned_32;
                         Id   : in Interfaces.Unsigned_32) with
     Post => Into.Pos = BT_DATA_START;

   procedure Put_Unsigned_16 (Into  : in out Marshaller;
                              Value : in Interfaces.Unsigned_16) with
     Pre => Into.Pos <= Block_Type'Last - 2;

   procedure Put_Unsigned_32 (Into  : in out Marshaller;
                              Value : in Interfaces.Unsigned_32) with
     Pre => Into.Pos <= Block_Type'Last - 4;

   procedure Put_Unsigned_64 (Into  : in out Marshaller;
                              Value : in Interfaces.Unsigned_64) with
     Pre => Into.Pos <= Block_Type'Last - 8;

   procedure Put_Kind (Into  : in out Marshaller;
                       Value : in Entry_Type) with
     Pre => Into.Pos <= Block_Type'Last - 4;

   procedure Put_Block_Number (Into  : in out Marshaller;
                               Value : in Block_Number) with
     Pre => Into.Pos <= Block_Type'Last - 4;

   procedure Put_String (Into  : in out Marshaller;
                         Value : in String) with
     Pre => Into.Pos < Block_Type'Last - 4 - Value'Length;

   procedure Put_Date (Into  : in out Marshaller;
                       Value : in Ada.Calendar.Time) with
     Pre => Into.Pos < Block_Type'Last - 8;

   procedure Put_Secret (Into        : in out Marshaller;
                         Value       : in Secret_Key;
                         Protect_Key : in Secret_Key) with
     Pre => Into.Pos < Block_Type'Last - Value.Length;

   procedure Put_Data (Into  : in out Marshaller;
                       Value : in Util.Encoders.AES.Word_Block_Type) with
     Pre => Into.Pos < Block_Type'Last - 16;

   procedure Put_HMAC_SHA256 (Into    : in out Marshaller;
                              Key     : in Ada.Streams.Stream_Element_Array;
                              Content : in Ada.Streams.Stream_Element_Array) with
     Pre => Into.Pos < Block_Type'Last - BT_HMAC_HEADER_SIZE;

   function Get_Unsigned_16 (From  : in out Marshaller) return Interfaces.Unsigned_16 with
     Pre => From.Pos <= Block_Type'Last - 2;

   function Get_Unsigned_32 (From  : in out Marshaller) return Interfaces.Unsigned_32 with
     Pre => From.Pos <= Block_Type'Last - 4;

   function Get_Unsigned_64 (From  : in out Marshaller) return Interfaces.Unsigned_64 with
     Pre => From.Pos <= Block_Type'Last - 8;

   function Get_String (From   : in out Marshaller;
                        Length : in Natural) return String with
     Pre => Stream_Element_Offset (Length) < Block_Type'Last and
     From.Pos <= Block_Type'Length - Stream_Element_Offset (Length);

   function Get_Date (From : in out Marshaller) return Ada.Calendar.Time with
     Pre => From.Pos <= Block_Type'Last - 8;

   function Get_Kind (From : in out Marshaller) return Entry_Type with
     Pre => From.Pos <= Block_Type'Last - 4;

   function Get_Block_Number (From : in out Marshaller) return Block_Number is
     (Block_Number (Get_Unsigned_32 (From)));

   function Get_Block_Index (From : in out Marshaller) return Block_Index is
     (Block_Index (Get_Unsigned_32 (From)));

   procedure Get_Secret (From        : in out Marshaller;
                         Secret      : out Secret_Key;
                         Protect_Key : in Secret_Key) with
     Pre => From.Pos < Block_Type'Last - IO.Block_Index (Secret.Length);

   procedure Get_Data (From  : in out Marshaller;
                       Value : out Ada.Streams.Stream_Element_Array) with
     Pre => From.Pos < Block_Type'Last - Value'Length;

   procedure Get_Data (From  : in out Marshaller;
                       Value : out Util.Encoders.AES.Word_Block_Type) with
     Pre => From.Pos < Block_Type'Last - 16;

   procedure Skip (From  : in out Marshaller;
                   Count : in Block_Index) with
     Pre => From.Pos < Block_Type'Last - Count;

end Keystore.IO;