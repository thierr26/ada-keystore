-----------------------------------------------------------------------
--  akt-commands-list -- List content of keystore
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
with Ada.Text_IO;
with Ada.Calendar.Formatting;
package body AKT.Commands.List is

   --  ------------------------------
   --  List the value entries of the keystore.
   --  ------------------------------
   overriding
   procedure Execute (Command   : in out Command_Type;
                      Name      : in String;
                      Args      : in Argument_List'Class;
                      Context   : in out Context_Type) is
      pragma Unreferenced (Command, Name);

      List : Keystore.Entry_Map;
      Iter : Keystore.Entry_Cursor;
   begin
      Context.Open_Keystore (Args);
      Context.Wallet.List (Content => List);
      Iter := List.First;
      while Keystore.Entry_Maps.Has_Element (Iter) loop
         declare
            Name : constant String := Keystore.Entry_Maps.Key (Iter);
            Item : constant Keystore.Entry_Info := Keystore.Entry_Maps.Element (Iter);
         begin
            if Name'Length > 50 then
               Ada.Text_IO.Put (Name (Name'First .. Name'First + 50));
            else
               Ada.Text_IO.Put (Name);
            end if;
            Ada.Text_IO.Set_Col (53);
            Ada.Text_IO.Put (Interfaces.Unsigned_64'Image (Item.Size));
            Ada.Text_IO.Set_Col (64);
            Ada.Text_IO.Put (Natural'Image (Item.Block_Count));
            Ada.Text_IO.Set_Col (72);
            Ada.Text_IO.Put (Ada.Calendar.Formatting.Image (Item.Create_Date));

            Ada.Text_IO.New_Line;
         end;
         Keystore.Entry_Maps.Next (Iter);
      end loop;
   end Execute;

end AKT.Commands.List;
