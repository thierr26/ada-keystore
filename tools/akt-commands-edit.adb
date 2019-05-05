-----------------------------------------------------------------------
--  akt-commands-edit -- Edit content in keystore
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
with Ada.Text_IO;
with Ada.Directories;
with Ada.Environment_Variables;
with Interfaces.C.Strings;
with Util.Files;
with Util.Processes;
with Util.Systems.Os;
with Util.Systems.Types;
with Util.Streams.Raw;
with Util.Log;
with Keystore.Random;
package body AKT.Commands.Edit is

   use GNAT.Strings;

   procedure Export_Value (Context : in out Context_Type;
                           Name    : in String;
                           Path    : in String);

   procedure Make_Directory (Path : in String);

   --  ------------------------------
   --  Export the named value from the wallet to the external file.
   --  The file is created and given read-write access to the current user only.
   --  ------------------------------
   procedure Export_Value (Context : in out Context_Type;
                           Name    : in String;
                           Path    : in String) is
      use Util.Systems.Os;
      use type Interfaces.C.int;
      use type Util.Systems.Types.File_Type;

      Fd   : Util.Systems.Os.File_Type;
      File : Util.Streams.Raw.Raw_Stream;
      P    : Interfaces.C.Strings.chars_ptr := Interfaces.C.Strings.New_String (Path);
   begin
      Fd := Util.Systems.Os.Sys_Open (Path  => P,
                                      Flags => O_CREAT + O_WRONLY + O_TRUNC,
                                      Mode  => 8#600#);
      if Fd < 0 then
         raise Error;
      end if;
      File.Initialize (Fd);
      if Context.Wallet.Contains (Name) then
         Context.Wallet.Write (Name, File);
      end if;
   end Export_Value;

   procedure Import_Value (Context : in out Context_Type;
                           Name    : in String;
                           Path    : in String) is
      use Util.Systems.Os;
      use type Interfaces.C.int;
      use type Util.Systems.Types.File_Type;

      Fd   : Util.Systems.Os.File_Type;
      File : Util.Streams.Raw.Raw_Stream;
      P    : Interfaces.C.Strings.chars_ptr := Interfaces.C.Strings.New_String (Path);
   begin
      Fd := Util.Systems.Os.Sys_Open (Path  => P,
                                      Flags => O_RDONLY,
                                      Mode  => 0);
      if Fd < 0 then
         raise Error;
      end if;
      File.Initialize (Fd);
      Context.Wallet.Set (Name, Keystore.T_STRING, File);
   end Import_Value;

   --  ------------------------------
   --  Get the editor command to launch.
   --  ------------------------------
   function Get_Editor (Command : in Command_Type) return String is
   begin
      if Command.Editor /= null and then Command.Editor'Length > 0 then
         return Command.Editor.all;
      end if;

      --  Use the $EDITOR if the environment variable defines it.
      if Ada.Environment_Variables.Exists ("EDITOR") then
         return Ada.Environment_Variables.Value ("EDITOR");
      end if;

      --  Use the editor which links to the default system-wide editor
      --  that can be configured on Ubuntu through /etc/alternatives.
      return "editor";
   end Get_Editor;

   --  ------------------------------
   --  Get the directory where the editor's file can be created.
   --  ------------------------------
   function Get_Directory (Command : in Command_Type;
                           Context : in out Context_Type) return String is
      Rand : Keystore.Random.Generator;
      Name : constant String := "akt-" & Rand.Generate (Bits => 32);
   begin
      return "/tmp/" & Name;
   end Get_Directory;

   procedure Make_Directory (Path : in String) is
      P : Interfaces.C.Strings.chars_ptr;
   begin
      Ada.Directories.Create_Path (Path);
      P := Interfaces.C.Strings.New_String (Path);
      if Util.Systems.Os.Sys_Chmod (P, 8#0700#) /= 0 then
         AKT.Commands.Log.Error ("Cannot set the permission of {0}", Path);
      end if;
      Interfaces.C.Strings.Free (P);
   end Make_Directory;

   --  ------------------------------
   --  Edit a value from the keystore by using an external editor.
   --  ------------------------------
   overriding
   procedure Execute (Command   : in out Command_Type;
                      Name      : in String;
                      Args      : in Argument_List'Class;
                      Context   : in out Context_Type) is
   begin
      if Args.Get_Count /= 1 then
         AKT.Commands.Usage (Args, Context, Name);

      else
         Context.Open_Keystore;
         declare
            Dir    : constant String := Command.Get_Directory (Context);
            Path   : constant String := Util.Files.Compose (Dir, "VALUE.txt");
            Editor : constant String := Command.Get_Editor;
            Proc   : Util.Processes.Process;
         begin
            Make_Directory (Dir);
            Export_Value (Context, Args.Get_Argument (1), Path);
            Util.Processes.Spawn (Proc, Editor & " " & Path);
            Util.Processes.Wait (Proc);
            if Util.Processes.Get_Exit_Status (Proc) = 0 then
               Ada.Text_IO.Put_Line ("Editor terminated");
               Import_Value (Context, Args.Get_Argument (1), Path);
            end if;
            Ada.Directories.Delete_File (Path);
            Ada.Directories.Delete_Tree (Dir);

         exception
            when others =>
               Ada.Directories.Delete_File (Path);
               Ada.Directories.Delete_Tree (Dir);
               raise;

         end;
      end if;
   end Execute;

   --  ------------------------------
   --  Setup the command before parsing the arguments and executing it.
   --  ------------------------------
   procedure Setup (Command : in out Command_Type;
                    Config  : in out GNAT.Command_Line.Command_Line_Configuration;
                    Context : in out Context_Type) is
      pragma Unreferenced (Context);

      package GC renames GNAT.Command_Line;
   begin
      GC.Define_Switch (Config, Command.Editor'Access,
                        "-e:", "--editor=", "Define the editor command to use");
   end Setup;

   --  ------------------------------
   --  Write the help associated with the command.
   --  ------------------------------
   overriding
   procedure Help (Command   : in out Command_Type;
                   Context   : in out Context_Type) is
      pragma Unreferenced (Command);
   begin
      AKT.Commands.Usage (Context, "edit");
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put_Line ("set: insert or update a value in the keystore");
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put_Line ("Usage: akt set <name> [<value> | -f <file>]");
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put_Line ("  The set command is used to store a content in the wallet.");
      Ada.Text_IO.Put_Line ("  The content is either passed as argument or read from a file.");
      Ada.Text_IO.Put_Line ("  If the wallet already contains the name, the value is updated.");
   end Help;

end AKT.Commands.Edit;