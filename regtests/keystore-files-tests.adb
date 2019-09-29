-----------------------------------------------------------------------
--  keystore-files-tests -- Tests for files
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

with Ahven;
with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Streams.Stream_IO;
with Util.Test_Caller;
with Util.Streams.Files;
with Util.Measures;
with Util.Streams.Buffered;
with Keystore.IO.Files;
package body Keystore.Files.Tests is

   package Caller is new Util.Test_Caller (Test, "Files");

   procedure Add_Tests (Suite : in Util.Tests.Access_Test_Suite) is
   begin
      Caller.Add_Test (Suite, "Test Keystore.Files.Create+Open",
                       Test_Create'Access);
      Caller.Add_Test (Suite, "Test Keystore.Add",
                       Test_Add'Access);
      Caller.Add_Test (Suite, "Test Keystore.Get",
                       Test_Add_Get'Access);
      Caller.Add_Test (Suite, "Test Keystore.Open (Corrupted keystore)",
                       Test_Corruption'Access);
      Caller.Add_Test (Suite, "Test Keystore.List",
                       Test_List'Access);
      Caller.Add_Test (Suite, "Test Keystore.Delete",
                       Test_Delete'Access);
      Caller.Add_Test (Suite, "Test Keystore.Update",
                       Test_Update'Access);
      Caller.Add_Test (Suite, "Test Keystore.Update (grow, shrink)",
                       Test_Update_Sequence'Access);
      Caller.Add_Test (Suite, "Test Keystore.Files.Open+Close",
                       Test_Open_Close'Access);
      Caller.Add_Test (Suite, "Test Keystore.Add (Name_Exist)",
                       Test_Add_Error'Access);
      Caller.Add_Test (Suite, "Test Keystore.Write",
                       Test_Get_Stream'Access);
      Caller.Add_Test (Suite, "Test Keystore.Add (Empty)",
                       Test_Add_Empty'Access);
      Caller.Add_Test (Suite, "Test Keystore.Add (Perf)",
                       Test_Perf_Add'Access);
      Caller.Add_Test (Suite, "Test Keystore.Set (Input_Stream < 4K)",
                       Test_Set_From_Stream'Access);
      Caller.Add_Test (Suite, "Test Keystore.Set (Input_Stream > 4K)",
                       Test_Set_From_Larger_Stream'Access);
      Caller.Add_Test (Suite, "Test Keystore.Set_Key",
                       Test_Set_Key'Access);
   end Add_Tests;

   --  ------------------------------
   --  Test creation of a keystore and re-opening it.
   --  ------------------------------
   procedure Test_Create (T : in out Test) is
      Path     : constant String := Util.Tests.Get_Test_Path ("regtests/result/test-create.akt");
      Password : Keystore.Secret_Key := Keystore.Create ("mypassword");
      Config   : Keystore.Wallet_Config := Unsecure_Config;
   begin
      declare
         W        : Keystore.Files.Wallet_File;
      begin
         Config.Overwrite := True;
         W.Create (Path => Path, Password => Password, Config => Config);
      end;
      declare
         Wread    : Keystore.Files.Wallet_File;
      begin
         Wread.Open (Path => Path, Password => Password);
      end;
      declare
         Wread    : Keystore.Files.Wallet_File;
         Bad      : Keystore.Secret_Key := Keystore.Create ("mypassword-bad");
      begin
         Wread.Open (Path => Path, Password => Bad);
         T.Fail ("No exception raised");

      exception
         when Bad_Password =>
            null;
      end;
      declare
         W        : Keystore.Files.Wallet_File;
      begin
         W.Create (Path => Path, Password => Password, Config => Unsecure_Config);
         T.Fail ("Create should raise Name_Error exception if the file exists");

      exception
         when Ada.IO_Exceptions.Name_Error =>
            null;
      end;
   end Test_Create;

   --  ------------------------------
   --  Test opening a keystore when some blocks are corrupted.
   --  ------------------------------
   procedure Test_Corruption (T : in out Test) is
      use type IO.Block_Index;
      use type IO.Block_Count;

      procedure Corrupt (Block : in IO.Block_Number;
                         Pos   : in IO.Block_Index);

      Path         : constant String
        := Util.Tests.Get_Path ("regtests/files/test-keystore.akt");

      Corrupt_Path : constant String
        := Util.Tests.Get_Test_Path ("regtests/result/test-corrupt.akt");

      procedure Corrupt (Block : in IO.Block_Number;
                         Pos   : in IO.Block_Index) is
         use type Ada.Streams.Stream_Element;

         --  Source_File  : IO.Files.Block_IO.File_Type;
         --  Corrupt_File : IO.Files.Block_IO.File_Type;
         Data         : IO.Block_Type;
         Last         : Ada.Streams.Stream_Element_Offset;
         Current      : IO.Block_Number := 1;
         Input_File   : Util.Streams.Files.File_Stream;
         Output_File  : Util.Streams.Files.File_Stream;
      begin
         Input_File.Open (Name => Path,
                          Mode => Ada.Streams.Stream_IO.In_File);
         Output_File.Create (Name => Corrupt_Path,
                             Mode => Ada.Streams.Stream_IO.Out_File);
         loop
            Input_File.Read (Data, Last);
            if Current = Block then
               Data (Pos) := Data (Pos) xor 1;
            end if;
            if Last > Data'First then
               Output_File.Write (Data (Data'First .. Last));
            end if;
            exit when Last < Data'Last;
            Current := Current + 1;
         end loop;
      end Corrupt;

      Password : Keystore.Secret_Key := Keystore.Create ("mypassword");
   begin
      for Block in IO.Block_Number (1) .. 3 loop
         for I in 1 .. IO.Block_Index'Last / 17 loop
            declare
               Pos   : constant IO.Block_Index := I * 17;
               W     : Keystore.Files.Wallet_File;
               Items : Keystore.Entry_Map;
            begin
               Corrupt (Block, Pos);
               W.Open (Password => Password,
                       Path     => Corrupt_Path);

               --  Block 1 and Block 2 are read by Open.
               --  Corruption must have been detected by Open.
               if Block <= 2 then
                  T.Fail ("No corruption detected block" & IO.Block_Number'Image (Block)
                          & " at" & IO.Block_Index'Image (Pos));
               end if;

               --  Block 3 is read only if we need the repository and datacontent.
               W.List (Items);

               W.Set ("no-corruption-detected", W.Get ("list-1"));
               T.Fail ("No corruption detected block" & IO.Block_Number'Image (Block)
                       & " at" & IO.Block_Index'Image (Pos));

            exception
               when Keystore.Corrupted =>
                  null;

               when Keystore.Invalid_Block =>
                  null;

               when Ahven.Assertion_Error =>
                  raise;

               when E : others =>
                  T.Fail ("Exception not expected: " & Ada.Exceptions.Exception_Name (E));
            end;
         end loop;
      end loop;
   end Test_Corruption;

   --  ------------------------------
   --  Test adding values to a keystore.
   --  ------------------------------
   procedure Test_Add (T : in out Test) is
      Path     : constant String := Util.Tests.Get_Test_Path ("regtests/result/test-add.akt");
      Password : Keystore.Secret_Key := Keystore.Create ("mypassword");
      Config   : Keystore.Wallet_Config := Unsecure_Config;
   begin
      Config.Overwrite := True;
      declare
         W        : Keystore.Files.Wallet_File;
      begin
         W.Create (Path => Path, Password => Password, Config => Config);
      end;
      declare
         W        : Keystore.Files.Wallet_File;
      begin
         W.Open (Path => Path, Password => Password);
         W.Add ("my-secret", "the secret");
         T.Assert (W.Contains ("my-secret"), "Property not contained in wallet");
      end;

      declare
         W        : Keystore.Files.Wallet_File;
      begin
         W.Open (Path => Path, Password => Password);
         T.Assert (W.Contains ("my-secret"), "Property not contained in wallet (load)");

         Util.Tests.Assert_Equals (T, "the secret", W.Get ("my-secret"),
                                   "Property cannot be retrieved from keystore");
         W.Add ("my-second-secret", "the second-secret");
         T.Assert (W.Contains ("my-second-secret"), "Property not contained in wallet");
         T.Assert (W.Contains ("my-secret"), "Property not contained in wallet");
      end;

   end Test_Add;

   --  ------------------------------
   --  Test adding values and getting them back.
   --  ------------------------------
   procedure Test_Add_Get (T : in out Test) is
      Path     : constant String := Util.Tests.Get_Test_Path ("regtests/result/test-add-get.akt");
      Password : Keystore.Secret_Key := Keystore.Create ("mypassword-add-get");
      Config   : Keystore.Wallet_Config := Unsecure_Config;
   begin
      Config.Overwrite := True;
      declare
         W        : Keystore.Files.Wallet_File;
      begin
         W.Create (Path => Path, Password => Password, Config => Config);
      end;

      for Pass in 1 .. 10 loop
         declare
            W        : Keystore.Files.Wallet_File;
         begin
            W.Open (Path => Path, Password => Password);

            W.Add ("my-second-secret " & Positive'Image (Pass),
                   "the second-secret padd " & Positive'Image (Pass));

            for Check in 1 .. Pass loop
               T.Assert (W.Contains ("my-second-secret " & Positive'Image (Check)),
                         "Property not contained in wallet " & Positive'Image (Check));
               Util.Tests.Assert_Equals (T, "the second-secret padd " & Positive'Image (Check),
                                         W.Get ("my-second-secret " & Positive'Image (Check)),
                                         "Cannot get property " & Positive'Image (Check));
            end loop;
         end;
      end loop;

   end Test_Add_Get;

   --  ------------------------------
   --  Test deleting values.
   --  ------------------------------
   procedure Test_Delete (T : in out Test) is
      Path     : constant String := Util.Tests.Get_Test_Path ("regtests/result/test-delete.akt");
      Password : Keystore.Secret_Key := Keystore.Create ("mypassword-delete");
      Config   : Keystore.Wallet_Config := Unsecure_Config;
   begin
      Config.Overwrite := True;
      declare
         W        : Keystore.Files.Wallet_File;
      begin
         W.Create (Path => Path, Password => Password, Config => Config);
         W.Add ("my-secret-1", "the secret 1");
         W.Add ("my-secret-2", "the secret 2");
         W.Add ("my-secret-3", "the secret 3");
         W.Add ("my-secret-4", "the secret 4");
      end;
      declare
         W        : Keystore.Files.Wallet_File;
      begin
         W.Open (Path => Path, Password => Password);
         W.Delete ("my-secret-2");
         T.Assert (not W.Contains ("my-secret-2"),
                   "Second property should have been removed");
         T.Assert (W.Contains ("my-secret-1"),
                   "First property should still be present");
         T.Assert (W.Contains ("my-secret-3"),
                   "Last property should still be present");
         T.Assert (W.Contains ("my-secret-4"),
                   "Last property should still be present");
      end;
   end Test_Delete;

   --  ------------------------------
   --  Test opening a keystore and listing the entries.
   --  ------------------------------
   procedure Test_List (T : in out Test) is
      procedure Verify_Entry (Name : in String; Size : in Integer);

      Path     : constant String := Util.Tests.Get_Test_Path ("regtests/files/test-keystore.akt");
      Password : Keystore.Secret_Key := Keystore.Create ("mypassword");
      W        : Keystore.Files.Wallet_File;
      Items    : Keystore.Entry_Map;

      procedure Verify_Entry (Name : in String; Size : in Integer) is
         Value : Keystore.Entry_Info;
      begin
         T.Assert (Items.Contains (Name), "Item " & Name & " should be in the wallet list");
         T.Assert (W.Contains (Name), "Wallet should contain:" & Name);

         Value := Items.Element (Name);
         Util.Tests.Assert_Equals (T, Size, Natural (Value.Size),
                                   "Item " & Name & " has invalid size");

         T.Assert (Value.Kind = Keystore.T_STRING, "Item " & Name & " should be a T_STRING");
      end Verify_Entry;

   begin
      W.Open (Path => Path, Password => Password);
      W.List (Items);
      Verify_Entry ("list-1", 63);
      Verify_Entry ("list-2", 64);
      Verify_Entry ("list-3", 39);
      Verify_Entry ("list-4", 42);
   end Test_List;

   --  ------------------------------
   --  Test update values.
   --  ------------------------------
   procedure Test_Update (T : in out Test) is
      Path     : constant String := Util.Tests.Get_Test_Path ("regtests/result/test-update.akt");
      Password : Keystore.Secret_Key := Keystore.Create ("mypassword");
      Count    : constant Natural := 10;
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;

      --  Step 1: create the keystore and add the values.
      declare
         W        : Keystore.Files.Wallet_File;
      begin
         W.Create (Path => Path, Password => Password, Config => Unsecure_Config);
         for I in 1 .. Count loop
            W.Add (Name    => "test-update" & Natural'Image (I),
                   Content => "Value before update" & Natural'Image (I));
         end loop;
      end;

      --  Step 2: open the keystore and update the values.
      declare
         W        : Keystore.Files.Wallet_File;
      begin
         W.Open (Path => Path, Password => Password);
         for I in 1 .. Count loop
            Util.Tests.Assert_Equals (T, "Value before update" & Natural'Image (I),
                                      W.Get ("test-update" & Natural'Image (I)),
                                      "Invalid property test-update" & Natural'Image (I));

            W.Update (Name    => "test-update" & Natural'Image (I),
                      Content => "Value after update" & Natural'Image (I));
         end loop;
         for I in 1 .. Count loop
            Util.Tests.Assert_Equals (T, "Value after update" & Natural'Image (I),
                                      W.Get ("test-update" & Natural'Image (I)),
                                      "Invalid property test-update" & Natural'Image (I));

            W.Update (Name    => "test-update" & Natural'Image (I),
                      Content => "Value after second update" & Natural'Image (I));
         end loop;
      end;

      --  Step 3: open the keystore, get the values, update them.
      declare
         W        : Keystore.Files.Wallet_File;
      begin
         W.Open (Path => Path, Password => Password);
         for I in 1 .. 1 loop
            Util.Tests.Assert_Equals (T, "Value after second update" & Natural'Image (I),
                                      W.Get ("test-update" & Natural'Image (I)),
                                      "Invalid property test-update" & Natural'Image (I));

            W.Update (Name    => "test-update" & Natural'Image (I),
                      Content => "Value after third update              " & Natural'Image (I));
         end loop;
      end;

      --  Step 4: open the keystore and verify the last values.
      declare
         W        : Keystore.Files.Wallet_File;
      begin
         W.Open (Path => Path, Password => Password);
         for I in 1 .. 1 loop
            Util.Tests.Assert_Equals (T, "Value after third update              "
                                      & Natural'Image (I),
                                      W.Get ("test-update" & Natural'Image (I)),
                                      "Invalid property test-update" & Natural'Image (I));
         end loop;
      end;
   end Test_Update;

   --  ------------------------------
   --  Test update values in growing and descending sequences.
   --  ------------------------------
   procedure Test_Update_Sequence (T : in out Test) is

      function Large (Len : in Positive; Content : in Character) return String;

      Path     : constant String := Util.Tests.Get_Test_Path ("regtests/result/test-sequence.akt");
      Password : Keystore.Secret_Key := Keystore.Create ("mypassword");

      function Large (Len : in Positive; Content : in Character) return String is
         Result : constant String (1 .. Len) := (others => Content);
      begin
         return Result;
      end Large;

   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;

      --  Step 1: create the keystore and add the values.
      declare
         W        : Keystore.Files.Wallet_File;
      begin
         W.Create (Path => Path, Password => Password, Config => Unsecure_Config);
         W.Add ("a", "b");
         W.Add ("c", "d");
         W.Add ("e", "f");

         --  Update with new size < 16 (content uses same number of AES block).
         W.Update ("a", "bcde");
         Util.Tests.Assert_Equals (T, "bcde",
                                   W.Get ("a"),
                                   "Cannot get property a");
         W.Update ("c", "ghij");
         Util.Tests.Assert_Equals (T, "ghij",
                                   W.Get ("c"),
                                   "Cannot get property c");
         W.Update ("e", "klmn");
         Util.Tests.Assert_Equals (T, "klmn",
                                   W.Get ("e"),
                                   "Cannot get property e");

         --  Update with size > 16 (a new AES block is necessary, hence shifting data in block).
         W.Update ("a", "0123456789abcdef12345");
         Util.Tests.Assert_Equals (T, "0123456789abcdef12345",
                                   W.Get ("a"),
                                   "Cannot get property a");
         W.Update ("c", "c0123456789abcdef12345");
         Util.Tests.Assert_Equals (T, "c0123456789abcdef12345",
                                   W.Get ("c"),
                                   "Cannot get property c");
         W.Update ("e", "e0123456789abcdef12345");
         Util.Tests.Assert_Equals (T, "e0123456789abcdef12345",
                                   W.Get ("e"),
                                   "Cannot get property e");
      end;

      --  Step 2: check the values.
      declare
         W        : Keystore.Files.Wallet_File;
      begin
         W.Open (Path => Path, Password => Password);
         Util.Tests.Assert_Equals (T, "0123456789abcdef12345",
                                   W.Get ("a"),
                                   "Cannot get property a");
         Util.Tests.Assert_Equals (T, "c0123456789abcdef12345",
                                   W.Get ("c"),
                                   "Cannot get property c");
         Util.Tests.Assert_Equals (T, "e0123456789abcdef12345",
                                   W.Get ("e"),
                                   "Cannot get property e");

         for I in 1 .. 5 loop
            declare
               L1 : constant String := Large (1024 * I, 'a');
               L2 : constant String := Large (1023 * I, 'b');
               L3 : constant String := Large (1022 * I, 'c');
            begin
               W.Update ("a", L1);
               Util.Tests.Assert_Equals (T, L1,
                                         W.Get ("a"),
                                         "Cannot get property a");

               W.Update ("c", "ghij");
               Util.Tests.Assert_Equals (T, "ghij",
                                         W.Get ("c"),
                                         "Cannot get property c");

               W.Update ("e", L2);
               Util.Tests.Assert_Equals (T, L2,
                                         W.Get ("e"),
                                         "Cannot get property e");

               W.Update ("a", "0123456789abcdef12345");
               Util.Tests.Assert_Equals (T, "0123456789abcdef12345",
                                         W.Get ("a"),
                                         "Cannot get property a");

               W.Update ("c", L3);
               Util.Tests.Assert_Equals (T, L3,
                                         W.Get ("c"),
                                         "Cannot get property c");
            end;
         end loop;
      end;
   end Test_Update_Sequence;

   --  ------------------------------
   --  Test opening and closing keystore.
   --  ------------------------------
   procedure Test_Open_Close (T : in out Test) is
      Path     : constant String := Util.Tests.Get_Test_Path ("regtests/files/test-keystore.akt");
      Password : Keystore.Secret_Key := Keystore.Create ("mypassword");
      W        : Keystore.Files.Wallet_File;
   begin
      --  Open and close the same wallet instance several times.
      for I in 1 .. 5 loop
         W.Open (Path => Path, Password => Password);
         Util.Tests.Assert_Equals (T, "http://www.apache.org/licenses/LICENSE-2.0",
                                   W.Get ("list-4"),
                                   "Cannot get property list-4");
         W.Close;
      end loop;
   end Test_Open_Close;

   --  ------------------------------
   --  Test adding values that already exist.
   --  ------------------------------
   procedure Test_Add_Error (T : in out Test) is
      Path     : constant String := Util.Tests.Get_Test_Path ("regtests/files/test-keystore.akt");
      Password : Keystore.Secret_Key := Keystore.Create ("mypassword");
      W        : Keystore.Files.Wallet_File;
   begin
      W.Open (Path => Path, Password => Password);
      begin
         W.Add ("list-1", "Value already contained in keystore, expect an exception");
         T.Fail ("No Name_Exist exception was raised for Add");
      exception
         when Keystore.Name_Exist =>
            null;
      end;
      begin
         W.Update ("list-invalid", "Value does not exist in keystore, expect an exception");
         T.Fail ("No Not_Found exception was raised for Add");
      exception
         when Keystore.Not_Found =>
            null;
      end;
      begin
         W.Delete ("list-invalid");
         T.Fail ("No Name_Exist exception was raised for Add");
      exception
         when Keystore.Not_Found =>
            null;
      end;
      begin
         T.Fail ("No Not_Found exception, returned value: " & W.Get ("list-invalid"));
      exception
         when Keystore.Not_Found =>
            null;
      end;

   end Test_Add_Error;

   --  ------------------------------
   --  Test changing the wallet password.
   --  ------------------------------
   procedure Test_Set_Key (T : in out Test) is
      Path         : constant String
        := Util.Tests.Get_Test_Path ("regtests/files/test-keystore.akt");
      Test_Path    : constant String
        := Util.Tests.Get_Test_Path ("regtests/result/test-set-key.akt");
      Password     : Keystore.Secret_Key := Keystore.Create ("mypassword");
      New_Password : Keystore.Secret_Key := Keystore.Create ("new-password");
   begin
      Ada.Directories.Copy_File (Source_Name => Path,
                                 Target_Name => Test_Path);
      declare
         W            : Keystore.Files.Wallet_File;
      begin
         W.Open (Path => Test_Path, Password => Password);
         W.Set_Key (Password, New_Password, Keystore.Unsecure_Config, Keystore.KEY_REPLACE);
      end;

      declare
         W            : Keystore.Files.Wallet_File;
      begin
         W.Open (Path => Test_Path, Password => Password);
         T.Fail ("No exception raised by Open after Set_Key");

      exception
         when Keystore.Bad_Password =>
            null;

         when others =>
            T.Fail ("Bad exception raised after Set_Key");
      end;
      declare
         W            : Keystore.Files.Wallet_File;
      begin
         W.Open (Path => Test_Path, Password => New_Password);
         W.Set_Key (New_Password, Password, Keystore.Unsecure_Config, Keystore.KEY_REPLACE);
      end;
      declare
         W            : Keystore.Files.Wallet_File;
      begin
         W.Open (Path => Test_Path, Password => Password);
         begin
            W.Set_Key (New_Password, New_Password, Keystore.Unsecure_Config, Keystore.KEY_REPLACE);
            T.Fail ("No exception raised by Set_Key");

         exception
            when Keystore.Bad_Password =>
               null;
         end;
      end;
      declare
         W            : Keystore.Files.Wallet_File;
      begin
         W.Open (Path => Test_Path, Password => Password);
         W.Set_Key (Password, New_Password, Keystore.Unsecure_Config, Keystore.KEY_ADD);
      end;

      --  Open the wallet with a first password and then the second one.
      declare
         W            : Keystore.Files.Wallet_File;
      begin
         W.Open (Path => Test_Path, Password => Password);
      end;
      declare
         W            : Keystore.Files.Wallet_File;
      begin
         W.Open (Path => Test_Path, Password => New_Password);
      end;

      --  Remove the password we added.
      declare
         W            : Keystore.Files.Wallet_File;
      begin
         W.Open (Path => Test_Path, Password => Password);
         W.Set_Key (New_Password, New_Password, Keystore.Unsecure_Config, Keystore.KEY_REMOVE);
      end;
   end Test_Set_Key;

   --  ------------------------------
   --  Test adding empty values to a keystore.
   --  ------------------------------
   procedure Test_Add_Empty (T : in out Test) is
      Path     : constant String := Util.Tests.Get_Test_Path ("regtests/result/test-empty.akt");
      Password : Keystore.Secret_Key := Keystore.Create ("mypassword");
      Config   : Keystore.Wallet_Config := Unsecure_Config;
   begin
      Config.Overwrite := True;
      declare
         W        : Keystore.Files.Wallet_File;
         Empty    : Util.Streams.Buffered.Input_Buffer_Stream;
      begin
         W.Create (Path => Path, Password => Password, Config => Config);
         W.Add ("empty-1", "");
         T.Assert (W.Contains ("empty-1"), "Property 'empty-1' not contained in wallet");

         Empty.Initialize ("");
         W.Add ("empty-2", T_BINARY, Empty);
         T.Assert (W.Contains ("empty-2"), "Property 'empty-2' not contained in wallet");

         Util.Tests.Assert_Equals (T, "", W.Get ("empty-1"),
                                   "Property 'empty-1' cannot be retrieved from keystore");
         Util.Tests.Assert_Equals (T, "", W.Get ("empty-2"),
                                   "Property 'empty-1' cannot be retrieved from keystore");
      end;
      declare
         W        : Keystore.Files.Wallet_File;
      begin
         W.Open (Path => Path, Password => Password);
         T.Assert (W.Contains ("empty-1"), "Property 'empty-1' not contained in wallet");
         T.Assert (W.Contains ("empty-2"), "Property 'empty-2' not contained in wallet");
         Util.Tests.Assert_Equals (T, "", W.Get ("empty-1"),
                                   "Property 'empty-1' cannot be retrieved from keystore");
         Util.Tests.Assert_Equals (T, "", W.Get ("empty-2"),
                                   "Property 'empty-1' cannot be retrieved from keystore");
      end;
   end Test_Add_Empty;

   --  ------------------------------
   --  Test getting values through an Output_Stream.
   --  ------------------------------
   procedure Test_Get_Stream (T : in out Test) is
      Path     : constant String := Util.Tests.Get_Test_Path ("regtests/files/test-keystore.akt");
      Output   : constant String := Util.Tests.Get_Path ("regtests/result/test-stream.txt");
      Expect   : constant String := Util.Tests.Get_Path ("regtests/expect/test-stream.txt");
      Password : Keystore.Secret_Key := Keystore.Create ("mypassword");
      W        : Keystore.Files.Wallet_File;
      File     : Util.Streams.Files.File_Stream;
   begin
      File.Create (Mode => Ada.Streams.Stream_IO.Out_File,
                   Name => Output);
      W.Open (Path => Path, Password => Password);
      W.Get (Name => "list-1", Output => File);
      W.Get (Name => "list-2", Output => File);
      W.Get (Name => "list-3", Output => File);
      W.Get (Name => "list-4", Output => File);
      W.Get (Name => "LICENSE.txt", Output => File);
      File.Close;

      Util.Tests.Assert_Equal_Files (T       => T,
                                     Expect  => Expect,
                                     Test    => Output,
                                     Message => "Write operation failed");
   end Test_Get_Stream;

   procedure Test_File_Stream (T     : in out Test;
                               Name  : in String;
                               Input : in String) is
      Path     : constant String := Util.Tests.Get_Test_Path ("regtests/result/test-stream.akt");
      Output   : constant String := Util.Tests.Get_Test_Path ("regtests/result/test-" & Name);
      Password : Keystore.Secret_Key := Keystore.Create ("mypassword");
      W        : Keystore.Files.Wallet_File;
      File     : Util.Streams.Files.File_Stream;
      Config   : Keystore.Wallet_Config := Unsecure_Config;
   begin
      Config.Overwrite := True;
      File.Open (Mode => Ada.Streams.Stream_IO.In_File,
                 Name => Input);
      W.Create (Path => Path, Password => Password, Config => Config);
      W.Set (Name => Name, Kind => Keystore.T_STRING, Input => File);
      File.Close;
      W.Close;

      W.Open (Path => Path, Password => Password);

      File.Create (Mode => Ada.Streams.Stream_IO.Out_File,
                   Name => Output);
      W.Get (Name => Name, Output => File);
      File.Close;

      Util.Tests.Assert_Equal_Files (T       => T,
                                     Expect  => Input,
                                     Test    => Output,
                                     Message => "Set or write operation failed for " & Name);
   end Test_File_Stream;

   --  ------------------------------
   --  Test setting values through an Input_Stream.
   --  ------------------------------
   procedure Test_Set_From_Stream (T : in out Test) is
      Input    : constant String := Util.Tests.Get_Path ("Makefile");
   begin
      T.Test_File_Stream ("makefile.txt", Input);
   end Test_Set_From_Stream;

   procedure Test_Set_From_Larger_Stream (T : in out Test) is
      Input    : constant String := Util.Tests.Get_Path ("LICENSE.txt");
   begin
      T.Test_File_Stream ("LICENSE.txt", Input);
   end Test_Set_From_Larger_Stream;

   --  ------------------------------
   --  Perforamce test adding values.
   --  ------------------------------
   procedure Test_Perf_Add (T : in out Test) is
      Path     : constant String := Util.Tests.Get_Test_Path ("regtests/result/test-perf.akt");
      Password : constant Keystore.Secret_Key := Keystore.Create ("mypassword");
      W        : Keystore.Files.Wallet_File;
      Items    : Keystore.Entry_Map;
      Config   : Keystore.Wallet_Config := Unsecure_Config;
   begin
      Config.Overwrite := True;
      W.Create (Path => Path, Password => Password, Config => Config);
      declare
         S     : Util.Measures.Stamp;
         Data  : String (1 .. 80);
      begin
         for I in 1 .. 10_000 loop
            Data := (others => Character'Val (30 + I mod 64));
            W.Add ("Item" & Natural'Image (I), Data);
         end loop;
         Util.Measures.Report (S, "Keystore.Add", 10_000);
      end;
      W.List (Items);
      Util.Tests.Assert_Equals (T, 10_000, Natural (Items.Length),
                                "Invalid number of items in keystore");
   end Test_Perf_Add;

end Keystore.Files.Tests;
