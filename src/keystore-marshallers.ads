-----------------------------------------------------------------------
--  keystore-marshallers -- Data marshaller for the keystore
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
with Keystore.Buffers;
private package Keystore.Marshallers is

   use Ada.Streams;

   --  Data block size defined to a 4K to map system page.
   Block_Size           : constant := 4096;

   BT_HMAC_HEADER_SIZE  : constant := 32;
   BT_TYPE_HEADER_SIZE  : constant := 16;

   --  Block type magic values.
   BT_WALLET_UNUSED     : constant := 16#0000#;
   BT_WALLET_HEADER     : constant := 16#0101#;
   BT_WALLET_REPOSITORY : constant := 16#0202#;
   BT_WALLET_DATA       : constant := 16#0303#;

   SIZE_U16             : constant := 2;
   SIZE_U32             : constant := 4;
   SIZE_U64             : constant := 8;
   SIZE_DATE            : constant := SIZE_U64;
   SIZE_HMAC            : constant := BT_HMAC_HEADER_SIZE;
   SIZE_KIND            : constant := SIZE_U32;
   SIZE_BLOCK           : constant := SIZE_U32;
   SIZE_SECRET          : constant := 32;
   SIZE_IV              : constant := 16;

   subtype Block_Count is Buffers.Block_Count;
   subtype Block_Number is Buffers.Block_Number;
   subtype Block_Index is Stream_Element_Offset range 1 .. Block_Size;
   subtype Buffer_Size is Buffers.Buffer_Size;

   subtype Block_Type is Stream_Element_Array (Block_Index);

   BT_HEADER_START : constant Block_Index := Block_Index'First + BT_HMAC_HEADER_SIZE;
   BT_DATA_START   : constant Block_Index := BT_HEADER_START + BT_TYPE_HEADER_SIZE;
   BT_DATA_LENGTH  : constant Block_Index := Block_Index'Last - BT_DATA_START + 1;

   type Marshaller;

   type Marshaller is limited record
      Buffer : Keystore.Buffers.Storage_Buffer;
      Pos    : Block_Index := Block_Type'First;
   end record;

   --  Set the block header with the tag and wallet identifier.
   procedure Set_Header (Into : in out Marshaller;
                         Tag  : in Interfaces.Unsigned_16;
                         Id   : in Keystore.Wallet_Identifier) with
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
     Pre => Into.Pos <= Block_Type'Last - 2;

   procedure Put_Block_Number (Into  : in out Marshaller;
                               Value : in Block_Number) with
     Pre => Into.Pos <= Block_Type'Last - 4;

   procedure Put_Block_Index (Into  : in out Marshaller;
                              Value : in Block_Index) with
     Pre => Into.Pos <= Block_Type'Last - 2;

   procedure Put_Buffer_Size (Into  : in out Marshaller;
                              Value : in Buffer_Size) with
     Pre => Into.Pos <= Block_Type'Last - 2;

   procedure Put_String (Into  : in out Marshaller;
                         Value : in String) with
     Pre => Into.Pos < Block_Type'Last - 4 - Value'Length;

   procedure Put_Date (Into  : in out Marshaller;
                       Value : in Ada.Calendar.Time) with
     Pre => Into.Pos < Block_Type'Last - 8;

   procedure Put_Storage_Block (Into  : in out Marshaller;
                                Value : in Buffers.Storage_Block) with
     Pre => Into.Pos < Block_Type'Last - 8;

   procedure Put_Secret (Into        : in out Marshaller;
                         Value       : in Secret_Key;
                         Protect_Key : in Secret_Key;
                         Protect_IV  : in Secret_Key) with
     Pre => Into.Pos < Block_Type'Last - Value.Length;

   procedure Put_HMAC_SHA256 (Into    : in out Marshaller;
                              Key     : in Secret_Key;
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
     Pre => From.Pos <= Block_Type'Last - 2;

   function Get_Block_Number (From : in out Marshaller) return Block_Count is
     (Block_Count (Get_Unsigned_32 (From)));

   function Get_Storage_Block (From : in out Marshaller) return Buffers.Storage_Block with
     Pre => From.Pos <= Block_Type'Last - 8;

   function Get_Block_Index (From : in out Marshaller) return Block_Index is
     (Block_Index (Get_Unsigned_16 (From)));

   function Get_Buffer_Size (From : in out Marshaller) return Buffer_Size is
     (Buffer_Size (Get_Unsigned_16 (From)));

   procedure Get_Secret (From        : in out Marshaller;
                         Secret      : out Secret_Key;
                         Protect_Key : in Secret_Key;
                         Protect_IV  : in Secret_Key);

   procedure Skip (From  : in out Marshaller;
                   Count : in Block_Index) with
     Pre => From.Pos < Block_Type'Last - Count;

end Keystore.Marshallers;