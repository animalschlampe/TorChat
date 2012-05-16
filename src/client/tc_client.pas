{ TorChat - TTorChatClient, this component is implememting the client

  Copyright (C) 2012 Bernd Kreuss <prof7bit@gmail.com>

  This source is free software; you can redistribute it and/or modify it under
  the terms of the GNU General Public License as published by the Free
  Software Foundation; either version 3 of the License, or (at your option)
  any later version.

  This code is distributed in the hope that it will be useful, but WITHOUT ANY
  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
  FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
  details.

  A copy of the GNU General Public License is available on the World Wide Web
  at <http://www.gnu.org/copyleft/gpl.html>. You can also obtain it by writing
  to the Free Software Foundation, Inc., 59 Temple Place - Suite 330, Boston,
  MA 02111-1307, USA.
}
unit tc_client;

{$mode objfpc}{$H+}

interface

uses
  Classes,
  SysUtils,
  tc_interface,
  tc_msgqueue,
  tc_tor,
  tc_sock;

type
  { TTorChatClient implements the abstract IClient.
    Together with all its contained objects this represents
    a fully functional TorChat client. The GUI (or
    libpurpletorchat or a command line client) will
    derive a class from TTorChatClient overriding the
    virtual event methods (the methods that start with On
    (see the definition of IClient) to hook into the
    events and then create an instance of it.
    The GUI also must call TorChatClient.Pump() in regular
    intervals (1 second or so) from within the GUI-thread.
    Aditionally whenever there is an incoming chat message,
    status change or other event then TorChatClient will
    fire the OnNotifyGui event and as a response the
    GUI should schedule an additional call to Pump()
    from the GUI thread immediately. All other event method
    calls will then always originate from the thread that
    is calling Pump(), this method will process one queued
    event per call, it will never block and if there are
    no events and nothing else to do it will just return.}
  TTorChatClient = class(TComponent, IClient)
  strict protected
    FMainThread: TThreadID;
    FProfileName: String;
    FClientConfig: IClientConfig;
    FRoster: IRoster;
    FTempList: ITempList;
    FNetwork: TSocketWrapper;
    FIsDestroying: Boolean;
    FTor: TTor;
    FQueue: IMsgQueue;
    FTimeStarted: TDateTime;
    FHSNameOK: Boolean;
    FConnInList: IInterfaceList;
    procedure CbNetIn(AStream: TTCPStream; E: Exception);
    procedure CheckHiddenServiceName;
  public
    constructor Create(AOwner: TComponent; AProfileName: String); reintroduce;
    destructor Destroy; override;
    procedure OnNotifyGui; virtual; abstract;
    procedure OnBuddyStatusChange(ABuddy: IBuddy); virtual; abstract;
    procedure OnBuddyAdded(ABuddy: IBuddy); virtual; abstract;
    procedure OnBuddyRemoved(ABuddy: IBuddy); virtual; abstract;
    function MainThread: TThreadID; virtual;
    function Roster: IRoster; virtual;
    function TempList: ITempList;
    function Network: TSocketWrapper; virtual;
    function Queue: IMsgQueue;
    function Config: IClientConfig; virtual;
    function IsDestroying: Boolean;
    procedure Pump; virtual;
    procedure SetStatus(AStatus: TTorchatStatus); virtual;
    procedure RegisterConnection(AConn: IHiddenConnection); virtual;
    procedure UnregisterConnection(AConn: IHiddenConnection); virtual;
  end;


implementation
uses
  tc_templist,
  tc_roster,
  tc_config,
  tc_misc,
  tc_conn;

{ TTorChatClient }

constructor TTorChatClient.Create(AOwner: TComponent; AProfileName: String);
begin
  FIsDestroying := False;
  Inherited Create(AOwner);
  FMainThread := ThreadID;
  FProfileName := AProfileName;
  FClientConfig := TClientConfig.Create(AProfileName);
  Randomize;
  FHSNameOK := False;
  FTimeStarted := 0; // we will initialize it on first Pump() call
  FConnInList := TInterfaceList.Create;
  FQueue := TMsgQueue.Create(self);
  FTor := TTor.Create(Self, Self);
  FNetwork := TSocketWrapper.Create(self);
  FRoster := TRoster.Create(self);
  FTempList := TTempList.Create(self);
  with FNetwork do begin
    SocksProxyAddress := Config.TorHostName;
    SocksProxyPort := Config.TorPort;
    IncomingCallback := @CbNetIn;
    Bind(Config.ListenPort);
  end;
end;

destructor TTorChatClient.Destroy;
var
  Conn: IHiddenConnection;
begin
  WriteLn(MilliTime, ' start destroying TorChatClient');
  FIsDestroying := True;

  // disconnect all buddies
  Roster.DoDisconnectAll;

  // disconnect all remaining incoming connections
  while FConnInList.Count > 0 do begin
    Conn := IHiddenConnection(FConnInList.Items[0]);
    Conn.DoClose;
  end;

  FRoster.Clear;
  FTempList.Clear;
  FQueue.Clear;

  WriteLn(MilliTime, ' start destroying child components');
  //FTor.Free;
  //FNetwork.Free;
  inherited Destroy;
  WriteLn(MilliTime, ' done destroying child components');
end;

function TTorChatClient.MainThread: TThreadID;
begin
  Result := FMainThread;
end;

function TTorChatClient.Roster: IRoster;
begin
  Result := FRoster;
end;

function TTorChatClient.TempList: ITempList;
begin
  Result := FTempList;
end;

function TTorChatClient.Network: TSocketWrapper;
begin
  Result := FNetwork;
end;

function TTorChatClient.Queue: IMsgQueue;
begin
  Result := FQueue;
end;

function TTorChatClient.Config: IClientConfig;
begin
  Result := FClientConfig;
end;

function TTorChatClient.IsDestroying: Boolean;
begin
  Result := FIsDestroying;
end;

procedure TTorChatClient.Pump;
begin
  if FIsDestroying then exit;
  if FTimeStarted = 0 then FTimeStarted := Now;
  CheckHiddenServiceName;
  Queue.PumpNext;
  Roster.CheckState;
end;

procedure TTorChatClient.SetStatus(AStatus: TTorchatStatus);
begin
  writeln('TTorChatClient.SetStatus(', AStatus, ')');
end;

procedure TTorChatClient.RegisterConnection(AConn: IHiddenConnection);
begin
  FConnInList.Add(AConn);
  WriteLn(_F(
    'TTorChatClient.RegisterConnection() have now %d incoming connections',
    [FConnInList.Count]));
end;

procedure TTorChatClient.UnregisterConnection(AConn: IHiddenConnection);
begin
  // only incoming connections are in this list
  if FConnInList.IndexOf(AConn) <> -1 then begin
    FConnInList.Remove(AConn);
    WriteLn(_F(
      'TTorChatClient.UnregisterConnection() removed %s, %d incoming connections left',
      [AConn.DebugInfo, FConnInList.Count]));
  end;
end;

procedure TTorChatClient.CbNetIn(AStream: TTCPStream; E: Exception);
var
  C : THiddenConnection;
begin
  writeln('TTorChatClient.CbNetIn()');
  Ignore(E);
  if FIsDestroying then
    AStream.Free
  else begin
    C := THiddenConnection.Create(self, AStream, nil);
    RegisterConnection(C);
  end;
end;

procedure TTorChatClient.CheckHiddenServiceName;
var
  HSName: String;
begin
  if not FHSNameOK then begin;
    if SecondsSince(FTimeStarted) < SECONDS_WAIT_FOR_HOSTNAME_FILE then begin
      HSName := Config.HiddenServiceName;
      if HSName <> '' then begin
        writeln('TTorChatClient.CheckHiddenServiceName() found: ' + HSName);
        Roster.SetOwnID(HSName);
        FHSNameOK := True;
      end
      else
        writeln('TTorChatClient.CheckHiddenServiceName() not found');
    end;
  end;
end;

end.
