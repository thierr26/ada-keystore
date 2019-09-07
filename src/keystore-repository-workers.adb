-----------------------------------------------------------------------
--  keystore-repository-data -- Data access and management for the keystore
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
with Interfaces;
with Util.Log.Loggers;
with Ada.IO_Exceptions;
with Keystore.Logs;
with Keystore.Buffers;
with Keystore.Marshallers;
with Keystore.Repository.Data;

package body Keystore.Repository.Workers is

   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   Log : constant Util.Log.Loggers.Logger
     := Util.Log.Loggers.Create ("Keystore.Repository.Workers");

   procedure Initialize_Queue (Manager : in out Wallet_Repository) is
   begin
      Manager.Workers.Sequence := 0;
      Manager.Workers.Data_Queue.Reset_Sequence;
   end Initialize_Queue;

   function Queue (Manager : in Wallet_Repository;
                   Work    : in Data_Work_Access) return Boolean is
   begin
      if Manager.Workers.Work_Manager /= null then
         Manager.Workers.Work_Manager.Execute (Work.all'Access);
         return True;
      else
         return False;
      end if;
   end Queue;

   procedure Fill (Work      : in out Data_Work;
                   Input     : in out Util.Streams.Input_Stream'Class;
                   Space     : in Buffer_Offset;
                   Data_Size : out Buffers.Buffer_Size) is
      Pos   : Buffer_Offset := Work.Data'First;
      Limit : constant Buffer_Offset := Pos + Space - 1;
      Last  : Stream_Element_Offset;
   begin
      Work.Buffer_Pos := 1;
      loop
         Input.Read (Work.Data (Pos .. Limit), Last);

         --  Reached end of buffer.
         if Last >= Limit then
            Work.Last_Pos := Limit;
            Data_Size := Last;
            return;
         end if;

         --  Reached end of stream.
         if Last < Pos then
            if Last >= Work.Data'First then
               Work.Last_Pos := Last;
               Data_Size := Last;
            else
               Data_Size := 0;
            end if;
            return;
         end if;
         Pos := Last + 1;
      end loop;
   end Fill;

   procedure Fill (Work      : in out Data_Work;
                   Input     : in Ada.Streams.Stream_Element_Array;
                   Input_Pos : in Ada.Streams.Stream_Element_Offset;
                   Data_Size : out Buffers.Buffer_Size) is
      Size : Stream_Element_Offset;
   begin
      Size := Input'Last - Input_Pos + 1;
      if Size > DATA_MAX_SIZE then
         Size := DATA_MAX_SIZE;
      end if;
      Data_Size := Size;
      Work.Last_Pos := Size;
      Work.Data (1 .. Size) := Input (Input_Pos .. Input_Pos + Size - 1);
   end Fill;

   procedure Put_Work (Worker : in out Wallet_Worker;
                       Work   : in Data_Work_Access) is
   begin
      Worker.Pool_Count := Worker.Pool_Count + 1;
      Worker.Work_Pool (Worker.Pool_Count) := Work;
   end Put_Work;

   function Get_Work (Worker : in out Wallet_Worker) return Data_Work_Access is
   begin
      if Worker.Pool_Count = 0 then
         return null;
      else
         Worker.Pool_Count := Worker.Pool_Count - 1;
         return Worker.Work_Pool (Worker.Pool_Count + 1);
      end if;
   end Get_Work;

   procedure Allocate_Work (Manager  : in out Wallet_Repository;
                            Kind     : in Data_Work_Type;
                            Process  : access procedure (Work : in Data_Work_Access);
                            Iterator : in Entries.Data_Key_Iterator;
                            Work     : out Data_Work_Access) is
      Workers : constant access Wallet_Worker := Manager.Workers;
      Seq     : Natural;
   begin
      loop
         Work := Get_Work (Workers.all);
         exit when Work /= null;
         Workers.Data_Queue.Dequeue (Work, Seq);
         if Process /= null then
            Process (Work);
         end if;
         Put_Work (Workers.all, Work);
      end loop;

      Work.Kind := Kind;
      Work.Buffer_Pos := Work.Data'First;
      if Kind = DATA_DECRYPT then
         Work.Last_Pos := Work.Data'First + Iterator.Data_Size - 1;
      end if;
      Work.Entry_Id := Iterator.Entry_Id;
      Work.Key_Pos := Iterator.Key_Pos;
      Work.Key_Block.Buffer := Iterator.Current.Buffer;
      Work.Data_Block := Iterator.Data_Block;
      Work.Data_Need_Setup := False;
      Work.Data_Offset := Iterator.Current_Offset;
      Work.Sequence := Workers.Sequence;
      Work.Status := PENDING;
      Workers.Sequence := Workers.Sequence + 1;
   end Allocate_Work;

   procedure Flush_Queue (Manager : in out Wallet_Repository;
                          Process : access procedure (Work : in Data_Work_Access)) is
      Workers : constant access Wallet_Worker := Manager.Workers;
      Seq     : Natural;
      Work    : Data_Work_Access;
   begin
      if Workers /= null then
         while Workers.Pool_Count < Workers.Work_Count loop
            Workers.Data_Queue.Dequeue (Work, Seq);
            if Process /= null then
               Process (Work);
            end if;
            Put_Work (Workers.all, Work);
         end loop;
      end if;
   end Flush_Queue;

   --  ------------------------------
   --  Load the data block in the wallet manager buffer.  Extract the data descriptors
   --  the first time the data block is read.
   --  ------------------------------
   procedure Load_Data (Work       : in out Data_Work;
                        Data_Block : in out IO.Marshaller) is
      Btype : Interfaces.Unsigned_16;
      Wid   : Interfaces.Unsigned_32;
      Size  : IO.Block_Index;
   begin
      Logs.Debug (Log, "Load data block{0} and key block{1}",
                  Work.Data_Block, Work.Key_Block.Buffer.Block);

      Data_Block.Buffer := Buffers.Allocate (Work.Data_Block);
      if Work.Data_Need_Setup then
         Work.Fragment_Count := 1;
         Work.Fragment_Pos := 1;
         Size := Work.Last_Pos - Work.Buffer_Pos + 1;
         Work.Start_Data := IO.Block_Index'Last - AES_Align (Size) + 1;
         Work.End_Aligned_Data := IO.Block_Index'Last;
         Work.End_Data := Work.Start_Data + Size - 1;
         Marshallers.Set_Header (Into => Data_Block,
                                 Tag  => IO.BT_WALLET_DATA,
                                 Id   => Work.Manager.Id);
         return;
      end if;

      --  Read wallet data block.
      Keys.Set_IV (Work.Info_Cryptor, Work.Data_Block.Block);
      Work.Stream.Read (Decipher     => Work.Info_Cryptor.Decipher,
                        Sign         => Work.Info_Cryptor.Sign,
                        Decrypt_Size => Size,
                        Into         => Data_Block.Buffer);

      Data_Block.Pos := IO.BT_HEADER_START;

      --  Check block type.
      Btype := Marshallers.Get_Unsigned_16 (Data_Block);
      if Btype /= IO.BT_WALLET_DATA then
         Logs.Error (Log, "Block{0} invalid block type", Data_Block.Buffer.Block);
         Work.Status := DATA_CORRUPTION;
         return;
      end if;
      Marshallers.Skip (Data_Block, 2);

      --  Check that this is a block for the current wallet.
      Wid := Marshallers.Get_Unsigned_32 (Data_Block);
      if Wid /= Interfaces.Unsigned_32 (Work.Manager.Id) then
         Logs.Error (Log, "Block{0} invalid block wallet identifier",
                     Work.Data_Block);
         Work.Status := DATA_CORRUPTION;
         return;
      end if;
      Marshallers.Skip (Data_Block, 8);

      declare
         Index        : Wallet_Entry_Index;
         Slot_Size    : IO.Buffer_Size;
         Data_Pos     : IO.Block_Index;
         Fragment_Pos : Natural := 0;
      begin
         Data_Pos := IO.Block_Index'Last;
         Work.Fragment_Count := Natural (Size / DATA_ENTRY_SIZE);
         while Data_Block.Pos < IO.BT_DATA_START + Size loop
            Index := Wallet_Entry_Index (Marshallers.Get_Unsigned_32 (Data_Block));
            Slot_Size := Marshallers.Get_Buffer_Size (Data_Block);
            if Index = Work.Entry_Id then
               Work.Fragment_Pos := Fragment_Pos + 1;
               Work.End_Aligned_Data := Data_Pos;
               Data_Pos := Data_Pos - AES_Align (Slot_Size) + 1;
               Work.Start_Data := Data_Pos;
               Work.End_Data := Data_Pos + Slot_Size - 1;
               Marshallers.Skip (Data_Block, 2);
               Work.Data_Offset := Marshallers.Get_Unsigned_64 (Data_Block);
               return;
            end if;
            Fragment_Pos := Fragment_Pos + 1;
            Data_Pos := Data_Pos - AES_Align (Slot_Size);
            Marshallers.Skip (Data_Block, DATA_ENTRY_SIZE - 4 - 2);
         end loop;
         Logs.Error (Log, "Block{0} does not contain expected data entry", Work.Data_Block);
         Work.Status := DATA_CORRUPTION;
      end;

   exception
      when Ada.IO_Exceptions.End_Error | Ada.IO_Exceptions.Data_Error =>
         Logs.Error (Log, "Block{0} cannot be read", Work.Data_Block);
         Work.Status := DATA_CORRUPTION;

   end Load_Data;

   procedure Do_Decipher_Data (Work : in out Data_Work) is
      Data_Block : IO.Marshaller;
      Last       : Stream_Element_Offset;
      Encoded    : Stream_Element_Offset;
      Secret     : Secret_Key (Length => Util.Encoders.AES.AES_256_Length);
      IV         : Secret_Key (Length => IO.SIZE_IV);
   begin
      if Log.Get_Level >= Util.Log.INFO_LEVEL then
         Log.Info ("Decipher data block{0} with key block{1} @{2} ({3} bytes)",
                    Buffers.To_String (Work.Data_Block),
                    Buffers.To_String (Work.Key_Block.Buffer.Block),
                    IO.Block_Index'Image (Work.Key_Pos),
                    IO.Block_Index'Image (Work.Last_Pos - Work.Buffer_Pos + 1));
      end if;

      --  Read the encrypted data block.
      Load_Data (Work, Data_Block);
      if Work.Status /= PENDING then
         return;
      end if;

      declare
         Buf : constant Buffers.Buffer_Accessor := Data_Block.Buffer.Data.Value;
      begin
         Work.Key_Block.Pos := Work.Key_Pos;
         Marshallers.Get_Secret (Work.Key_Block, IV, Work.Manager.Config.Key.Key,
                                 Work.Manager.Config.Key.IV);
         Marshallers.Get_Secret (Work.Key_Block, Secret, Work.Manager.Config.Key.Key,
                                 Work.Manager.Config.Key.IV);

         Work.Data_Decipher.Set_IV (IV, (others => 0));
         Work.Data_Decipher.Set_Key (Secret, Util.Encoders.AES.CBC);
         Work.Data_Decipher.Set_Padding (Util.Encoders.AES.ZERO_PADDING);

         Work.Data_Decipher.Transform
           (Data    => Buf.Data (Work.Start_Data .. Work.End_Aligned_Data),
            Into    => Work.Data (Work.Buffer_Pos .. Work.Last_Pos),
            Last    => Last,
            Encoded => Encoded);

         Work.Data_Decipher.Finish (Into => Work.Data (Last + 1 .. Work.Last_Pos),
                                    Last => Last);

         if Log.Get_Level >= Util.Log.DEBUG_LEVEL then
            Log.Debug ("Key pos for decrypt at {0}", IO.Block_Index'Image (Work.Key_Pos));
            Log.Debug ("Current pos {0}", IO.Block_Index'Image (Work.Key_Block.Pos));

            Log.Debug ("Dump encrypted data:");
            Logs.Dump (Log, Buf.Data (Work.Start_Data .. Work.End_Aligned_Data));

            Log.Debug ("Dump data:");
            Logs.Dump (Log, Work.Data (Work.Buffer_Pos .. Work.Last_Pos));
         end if;
         Work.Status := SUCCESS;
      end;

   exception
      when E : others =>
         Work.Status := DATA_CORRUPTION;
   end Do_Decipher_Data;

   procedure Do_Cipher_Data (Work : in out Data_Work) is
      Data_Block   : IO.Marshaller;
      Encoded      : Stream_Element_Offset;
      Start_Pos    : constant Stream_Element_Offset := Work.Buffer_Pos;
      Last_Pos     : constant Stream_Element_Offset := Work.Last_Pos;
      Write_Pos    : Stream_Element_Offset;
      Secret       : Secret_Key (Length => Util.Encoders.AES.AES_256_Length);
      IV           : Secret_Key (Length => 16);
   begin
      if Log.Get_Level >= Util.Log.INFO_LEVEL then
         Log.Info ("Cipher data block{0} with key block{1} @{2} ({3} bytes)",
                    Buffers.To_String (Work.Data_Block),
                    Buffers.To_String (Work.Key_Block.Buffer.Block),
                    IO.Block_Index'Image (Work.Key_Pos),
                    IO.Block_Index'Image (Work.Last_Pos - Work.Buffer_Pos + 1));
      end if;

      --  Read the encrypted data block.
      Load_Data (Work, Data_Block);
      if Work.Status /= PENDING then
         return;
      end if;

      --  Generate a new IV and key.
      Work.Random.Generate (IV);
      Work.Random.Generate (Secret);

      Work.Key_Block.Pos := Work.Key_Pos;
      Marshallers.Put_Secret (Work.Key_Block, IV, Work.Manager.Config.Key.Key,
                              Work.Manager.Config.Key.IV);
      Marshallers.Put_Secret (Work.Key_Block, Secret, Work.Manager.Config.Key.Key,
                              Work.Manager.Config.Key.IV);

      --  Encrypt the data content using the item encryption key and IV.
      Work.Data_Cipher.Set_IV (IV, (others => 0));
      Work.Data_Cipher.Set_Key (Secret, Util.Encoders.AES.CBC);
      Work.Data_Cipher.Set_Padding (Util.Encoders.AES.ZERO_PADDING);

      Data_Block.Pos := Data.Data_Entry_Offset (Work.Fragment_Pos);
      Marshallers.Put_Unsigned_32 (Data_Block, Interfaces.Unsigned_32 (Work.Entry_Id));
      Marshallers.Put_Unsigned_16 (Data_Block, Interfaces.Unsigned_16 (Last_Pos - Start_Pos + 1));
      Marshallers.Put_Unsigned_16 (Data_Block, 0);
      Marshallers.Put_Unsigned_64 (Data_Block, Work.Data_Offset);

      --  Make HMAC-SHA256 signature of the data content before encryption.
      Marshallers.Put_HMAC_SHA256 (Into    => Data_Block,
                                   Key     => Work.Info_Cryptor.Sign,
                                   Content => Work.Data (Start_Pos .. Last_Pos));

      declare
         Buf : constant Buffers.Buffer_Accessor := Data_Block.Buffer.Data.Value;
         Encrypt_Size : IO.Block_Index;
      begin
         Encrypt_Size := IO.Block_Index (Work.Fragment_Count * DATA_ENTRY_SIZE);

         Work.Data_Cipher.Transform (Data    => Work.Data (Start_Pos .. Last_Pos),
                                     Into    => Buf.Data (Work.Start_Data .. Work.End_Aligned_Data),
                                     Last    => Write_Pos,
                                     Encoded => Encoded);
         if Write_Pos < Work.End_Aligned_Data then
            Work.Data_Cipher.Finish (Into => Buf.Data (Write_Pos + 1 .. Work.End_Aligned_Data),
                                     Last => Write_Pos);
         end if;

         --  Write the encrypted data block.
         Keys.Set_IV (Work.Info_Cryptor, Work.Data_Block.Block);
         Work.Stream.Write (Encrypt_Size => Encrypt_Size,
                            Cipher       => Work.Info_Cryptor.Cipher,
                            Sign         => Work.Info_Cryptor.Sign,
                            From         => Data_Block.Buffer);
         if Log.Get_Level >= Util.Log.DEBUG_LEVEL then
            Log.Debug ("Key pos for encryption at {0}", IO.Block_Index'Image (Work.Key_Pos));
            Log.Debug ("Current pos {0}", IO.Block_Index'Image (Work.Key_Block.Pos));

            Log.Debug ("Dump clear data:");
            Logs.Dump (Log, Work.Data (Start_Pos .. Last_Pos));

            Log.Debug ("Dump encrypted data:");
            Logs.Dump (Log, Buf.Data (Work.Start_Data .. Work.End_Aligned_Data));

         end if;
         Work.Status := SUCCESS;
      end;

   exception
      when E : others =>
         Work.Status := DATA_CORRUPTION;
   end Do_Cipher_Data;

   procedure Do_Delete_Data (Work : in out Data_Work) is
      Data_Block   : IO.Marshaller;
   begin
      Logs.Debug (Log, "Delete data in{0}", Work.Data_Block);

      --  Read the encrypted data block to release the data fragment or the full data block.
      Load_Data (Work, Data_Block);
      if Work.Status /= PENDING then
         return;
      end if;

      if Work.Fragment_Count > 1 then
         --  The data block looks like:
         --  +-----+-----------------------------+-----+----------------------------------------+
         --  | HDR | Ent1 | ... | Enti | ... EntN| 0 0 | xxx | FragN | .. | Fragi | ... | Frag1 |
         --  +-----+-----------------------------+-----+----------------------------------------+
         --
         --  When we remove entry I, we also remove the fragment I.
         --  +-----+------------------+------------------------------------+--------------------+
         --  | HDR | Ent1 | ... | EntN| 0 0 | xxx                          | FragN | .. | Frag1 |
         --  +-----+------------------+------------------------------------+--------------------+
         --
         declare
            Buf          : constant Buffers.Buffer_Accessor := Data_Block.Buffer.Data.Value;
            Start_Entry  : IO.Block_Index;
            Last_Entry   : IO.Block_Index;
            Start_Pos    : IO.Block_Index;
            Slot_Size    : IO.Buffer_Size;
            Data_Size    : constant IO.Block_Index := Work.End_Aligned_Data - Work.Start_Data;
            Encrypt_Size : constant IO.Block_Index
              := Data.Data_Entry_Offset (Work.Fragment_Count);
         begin
            Last_Entry := Data.Data_Entry_Offset (Work.Fragment_Count) + DATA_ENTRY_SIZE - 1;

            --  Move the data entry to the beginning.
            if Work.Fragment_Pos /= Work.Fragment_Count then
               Start_Entry := Data.Data_Entry_Offset (Work.Fragment_Pos);
               Buf.Data (Start_Entry .. Last_Entry - DATA_ENTRY_SIZE)
                 := Buf.Data (Start_Entry + DATA_ENTRY_SIZE .. Last_Entry);
            end if;
            Buf.Data (Last_Entry - DATA_ENTRY_SIZE + 1 .. Last_Entry) := (others => 0);

            Start_Pos := Work.Start_Data;
            Data_Block.Pos := Start_Entry + 4;
            while Data_Block.Pos < Last_Entry - DATA_ENTRY_SIZE loop
               Slot_Size := Marshallers.Get_Buffer_Size (Data_Block);
               Start_Pos := Start_Pos - AES_Align (Slot_Size);
               Marshallers.Skip (Data_Block, DATA_ENTRY_SIZE - 2);
            end loop;

            --  Move the data before the slot being removed.
            if Work.Start_Data /= Start_Pos then
               Buf.Data (Start_Pos + Data_Size .. Work.Start_Data - 1)
                 := Buf.Data (Start_Pos .. Work.End_Aligned_Data);
            end if;

            --  Erase the content that was dropped.
            Buf.Data (Start_Pos .. Start_Pos + Data_Size - 1) := (others => 0);

            --  Write the data block.
            Work.Stream.Write (Encrypt_Size => Encrypt_Size,
                               Cipher       => Work.Info_Cryptor.Cipher,
                               Sign         => Work.Info_Cryptor.Sign,
                               From         => Data_Block.Buffer);
         end;
      else
         Work.Stream.Release (Block => Work.Data_Block);
      end if;
      Work.Status := SUCCESS;
   end Do_Delete_Data;

   overriding
   procedure Execute (Work : in out Data_Work) is
   begin
      begin
         case Work.Kind is
         when DATA_ENCRYPT =>
            Work.Do_Cipher_Data;

         when DATA_DECRYPT =>
            Work.Do_Decipher_Data;

         when DATA_RELEASE =>
            Work.Do_Delete_Data;

         end case;

      exception
         when E : others =>
            Log.Error ("Unexpected exception", E);
            Work.Status := DATA_CORRUPTION;

      end;
      Work.Queue.Enqueue (Work'Unchecked_Access, Work.Sequence);
   end Execute;

   procedure Check_Raise_Error (Work : in Data_Work) is
   begin
      case Work.Status is
         when DATA_CORRUPTION =>
            raise Keystore.Corrupted;

         when PENDING | SUCCESS =>
            null;

         when others =>
            raise Keystore.Invalid_Block;

      end case;
   end Check_Raise_Error;

   --  ------------------------------
   --  Create the wallet encryption and decryption work manager.
   --  ------------------------------
   function Create (Manager      : access Wallet_Repository;
                    Work_Manager : in Keystore.Task_Manager_Access;
                    Count        : in Positive) return Wallet_Worker_Access is
      Result : Wallet_Worker_Access := new Wallet_Worker (Count);
      Work   : Data_Work_Access;
   begin
      Result.Work_Manager := Work_Manager;
      Result.Data_Queue.Set_Size (Capacity => Count);
      for I in 1 .. Count loop
         Work := Result.Work_Slots (I)'Access;
         Work.Stream := Manager.Stream;
         Keys.Set_Key (Work.Info_Cryptor, Manager.Config.Data);
         Result.Work_Pool (I) := Work;
         Result.Work_Slots (I).Queue := Result.Data_Queue'Access;
         Result.Work_Slots (I).Manager := Manager;
      end loop;
      Result.Pool_Count := Count;
      return Result;
   end Create;

end Keystore.Repository.Workers;