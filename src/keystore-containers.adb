-----------------------------------------------------------------------
--  keystore-containers -- Container protected keystore
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
with Keystore.IO;
with Util.Encoders;
package body Keystore.Containers is

   Header_Key : constant Secret_Key
     := Util.Encoders.Create ("If you can't give me poetry, can't you give me poetical science?");

   protected body Wallet_Container is

      procedure Open (Ident         : in Wallet_Identifier;
                      Block         : in Keystore.IO.Storage_Block;
                      Wallet_Stream : in out Keystore.IO.Refs.Stream_Ref) is
      begin
         Keys.Set_Header_Key (Master, Header_Key);
         Stream := Wallet_Stream;
         Master_Block := Block;
         Master_Ident := Ident;
         State := S_PROTECTED;
      end Open;

      procedure Create (Password      : in out Keystore.Passwords.Provider'Class;
                        Config        : in Wallet_Config;
                        Block         : in IO.Storage_Block;
                        Ident         : in Wallet_Identifier;
                        Wallet_Stream : in out IO.Refs.Stream_Ref) is
      begin
         Stream := Wallet_Stream;
         Master_Block := Block;
         Master_Ident := Ident;
         Keys.Set_Header_Key (Master, Header_Key);
         Keystore.Repository.Create (Repository, Password, Config, Block, Ident,
                                     Master, Stream.Value);
         State := S_OPEN;
      end Create;

      procedure Set_Header_Data (Index     : in Header_Slot_Index_Type;
                                 Kind      : in Header_Slot_Type;
                                 Data      : in Ada.Streams.Stream_Element_Array) is
      begin
         Stream.Value.Set_Header_Data (Index, Kind, Data);
      end Set_Header_Data;

      procedure Get_Header_Data (Index     : in Header_Slot_Index_Type;
                                 Kind      : out Header_Slot_Type;
                                 Data      : out Ada.Streams.Stream_Element_Array;
                                 Last      : out Ada.Streams.Stream_Element_Offset) is
      begin
         Stream.Value.Get_Header_Data (Index, Kind, Data, Last);
      end Get_Header_Data;

      procedure Unlock (Password  : in out Keystore.Passwords.Provider'Class;
                        Slot      : out Key_Slot) is
      begin
         Keystore.Repository.Open (Repository, Password, Master_Ident,
                                   Master_Block, Master, Stream.Value);
         Slot := Repository.Get_Key_Slot;
         State := S_OPEN;
      end Unlock;

      procedure Unlock (Master_Password : in out Keystore.Passwords.Provider'Class;
                        Password        : in out Keystore.Passwords.Provider'Class;
                        Slot            : out Key_Slot) is
      begin
         Keystore.Keys.Set_Master_Key (Master, Master_Password);
         Keystore.Repository.Open (Repository, Password, Master_Ident,
                                   Master_Block, Master, Stream.Value);
         Slot := Repository.Get_Key_Slot;
         State := S_OPEN;
      end Unlock;

      procedure Set_Key (Password     : in out Keystore.Passwords.Provider'Class;
                         New_Password : in out Keystore.Passwords.Provider'Class;
                         Config       : in Wallet_Config;
                         Mode         : in Mode_Type) is
      begin
         Keystore.Keys.Set_Key (Master, Password, New_Password, Config, Mode,
                                Repository.Get_Identifier, Master_Block, Stream.Value.all);
      end Set_Key;

      procedure Remove_Key (Password : in out Keystore.Passwords.Provider'Class;
                            Slot     : in Key_Slot;
                            Force    : in Boolean) is
      begin
         Keystore.Keys.Remove_Key (Master, Password, Slot, Force,
                                   Repository.Get_Identifier, Master_Block, Stream.Value.all);
      end Remove_Key;

      function Get_State return State_Type is
      begin
         return State;
      end Get_State;

      function Contains (Name : in String) return Boolean is
      begin
         return Keystore.Repository.Contains (Repository, Name);
      end Contains;

      procedure Add (Name    : in String;
                     Kind    : in Entry_Type;
                     Content : in Ada.Streams.Stream_Element_Array) is
      begin
         Keystore.Repository.Add (Repository, Name, Kind, Content);
      end Add;

      procedure Add (Name    : in String;
                     Kind    : in Entry_Type;
                     Input   : in out Util.Streams.Input_Stream'Class) is
      begin
         Keystore.Repository.Add (Repository, Name, Kind, Input);
      end Add;

      procedure Create (Name             : in String;
                        Password         : in out Keystore.Passwords.Provider'Class;
                        From_Repo        : in out Keystore.Repository.Wallet_Repository;
                        From_Stream      : in out IO.Refs.Stream_Ref) is
      begin
         Keystore.Repository.Add_Wallet (From_Repo, Name, Password, Master,
                                         Master_Block, Master_Ident, Repository);
         Stream := From_Stream;
         State := S_OPEN;
      end Create;

      procedure Open (Name             : in String;
                      Password         : in out Keystore.Passwords.Provider'Class;
                      From_Repo        : in out Keystore.Repository.Wallet_Repository;
                      From_Stream      : in out IO.Refs.Stream_Ref) is
      begin
         Keystore.Repository.Open (From_Repo, Name, Password, Master,
                                   Master_Block, Master_Ident, Repository);
         Stream := From_Stream;
         State := S_OPEN;
      end Open;

      procedure Do_Repository (Process : not null access
                                 procedure (Repo   : in out Keystore.Repository.Wallet_Repository;
                                            Stream : in out IO.Refs.Stream_Ref)) is
      begin
         Process (Repository, Stream);
      end Do_Repository;

      procedure Set (Name    : in String;
                     Kind    : in Entry_Type;
                     Content : in Ada.Streams.Stream_Element_Array) is
      begin
         Keystore.Repository.Set (Repository, Name, Kind, Content);
      end Set;

      procedure Set (Name    : in String;
                     Kind    : in Entry_Type;
                     Input   : in out Util.Streams.Input_Stream'Class) is
      begin
         Keystore.Repository.Set (Repository, Name, Kind, Input);
      end Set;

      procedure Update (Name    : in String;
                        Kind    : in Entry_Type;
                        Content : in Ada.Streams.Stream_Element_Array) is
      begin
         Keystore.Repository.Update (Repository, Name, Kind, Content);
      end Update;

      procedure Delete (Name : in String) is
      begin
         Keystore.Repository.Delete (Repository, Name);
      end Delete;

      procedure Find (Name   : in String;
                      Result : out Entry_Info) is
      begin
         Keystore.Repository.Find (Repository, Name, Result);
      end Find;

      procedure Get_Data (Name       : in String;
                          Result     : out Entry_Info;
                          Output     : out Ada.Streams.Stream_Element_Array) is
      begin
         Keystore.Repository.Get_Data (Repository, Name, Result, Output);
      end Get_Data;

      procedure Get_Data (Name      : in String;
                          Output    : in out Util.Streams.Output_Stream'Class) is
      begin
         Keystore.Repository.Get_Data (Repository, Name, Output);
      end Get_Data;

      procedure List (Filter  : in Filter_Type;
                      Content : out Entry_Map) is
      begin
         Keystore.Repository.List (Repository, Filter, Content);
      end List;

      procedure List (Pattern : in GNAT.Regpat.Pattern_Matcher;
                      Filter  : in Filter_Type;
                      Content : out Entry_Map) is
      begin
         Keystore.Repository.List (Repository, Pattern, Filter, Content);
      end List;

      procedure Get_Stats (Stats : out Wallet_Stats) is
      begin
         Repository.Fill_Stats (Stats);
      end Get_Stats;

      procedure Close is
      begin
         Keystore.Repository.Close (Repository);
         Stream := IO.Refs.Null_Ref;
         State := S_CLOSED;
      end Close;

      procedure Set_Work_Manager (Workers   : in Keystore.Task_Manager_Access) is
      begin
         Keystore.Repository.Set_Work_Manager (Repository, Workers);
      end Set_Work_Manager;

   end Wallet_Container;

   procedure Open_Wallet (Container : in out Wallet_Container;
                          Name      : in String;
                          Password  : in out Keystore.Passwords.Provider'Class;
                          Wallet    : in out Wallet_Container) is
      procedure Add (Repo         : in out Keystore.Repository.Wallet_Repository;
                     Stream       : in out IO.Refs.Stream_Ref);

      procedure Add (Repo         : in out Keystore.Repository.Wallet_Repository;
                     Stream       : in out IO.Refs.Stream_Ref) is
      begin
         Wallet.Open (Name, Password, Repo, Stream);
      end Add;

   begin
      Container.Do_Repository (Add'Access);
   end Open_Wallet;

   procedure Add_Wallet (Container : in out Wallet_Container;
                         Name      : in String;
                         Password  : in out Keystore.Passwords.Provider'Class;
                         Wallet    : in out Wallet_Container) is
      procedure Add (Repo         : in out Keystore.Repository.Wallet_Repository;
                     Stream       : in out IO.Refs.Stream_Ref);

      procedure Add (Repo         : in out Keystore.Repository.Wallet_Repository;
                     Stream       : in out IO.Refs.Stream_Ref) is
      begin
         Wallet.Create (Name, Password, Repo, Stream);
      end Add;

   begin
      Container.Do_Repository (Add'Access);
   end Add_Wallet;

end Keystore.Containers;
