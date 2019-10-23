library socks;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dart:typed_data';

/// https://tools.ietf.org/html/rfc1928
///

class AuthMethods {
  static const NoAuth = const AuthMethods._(0x00);
  static const GSSApi = const AuthMethods._(0x01);
  static const UsernamePassword = const AuthMethods._(0x02);
  static const NoAcceptableMethods = const AuthMethods._(0xFF);

  final int _value;

  const AuthMethods._(this._value);

  String toString() {
    return const {
      0x00: 'AuthMethods.NoAuth',
      0x01: 'AuthMethods.GSSApi',
      0x02: 'AuthMethods.UsernamePassword',
      0xFF: 'AuthMethods.NoAcceptableMethods'
    }[_value];
  }
}

class SOCKSState {
  static const Starting = const SOCKSState._(0x00);
  static const Auth = const SOCKSState._(0x01);
  static const RequestReady = const SOCKSState._(0x02);
  static const Connected = const SOCKSState._(0x03);

  final int _value;

  const SOCKSState._(this._value);

  String toString() {
    return const [
      'SOCKSState.Starting',
      'SOCKSState.Auth',
      'SOCKSState.RequestReady',
      'SOCKSState.Connected',
    ][_value];
  }
}

class SOCKSAddressType {
  static const IPv4 = const SOCKSAddressType._(0x01);
  static const Domain = const SOCKSAddressType._(0x03);
  static const IPv6 = const SOCKSAddressType._(0x04);

  final int _value;

  const SOCKSAddressType._(this._value);

  String toString() {
    return const [
      null,
      'SOCKSAddressType.IPv4',
      null,
      'SOCKSAddressType.Domain',
      'SOCKSAddressType.IPv6',
    ][_value];
  }
}

class SOCKSCommand {
  static const Connect = const SOCKSCommand._(0x01);
  static const Bind = const SOCKSCommand._(0x02);
  static const UDPAssociate = const SOCKSCommand._(0x03);

  final int _value;

  const SOCKSCommand._(this._value);

  String toString() {
    return const [
      null,
      'SOCKSCommand.Connect',
      'SOCKSCommand.Bind',
      'SOCKSCommand.UDPAssociate',
    ][_value];
  }
}

class SOCKSReply {
  static const Success = const SOCKSReply._(0x00);
  static const GeneralFailure = const SOCKSReply._(0x01);
  static const ConnectionNotAllowedByRuleset = const SOCKSReply._(0x02);
  static const NetworkUnreachable = const SOCKSReply._(0x03);
  static const HostUnreachable = const SOCKSReply._(0x04);
  static const ConnectionRefused = const SOCKSReply._(0x05);
  static const TTLExpired = const SOCKSReply._(0x06);
  static const CommandNotSupported = const SOCKSReply._(0x07);
  static const AddressTypeNotSupported = const SOCKSReply._(0x08);

  final int _value;

  const SOCKSReply._(this._value);

  String toString() {
    return const [
      'SOCKSReply.Success',
      'SOCKSReply.GeneralFailure',
      'SOCKSReply.ConnectionNotAllowedByRuleset',
      'SOCKSReply.NetworkUnreachable',
      'SOCKSReply.HostUnreachable',
      'SOCKSReply.ConnectionRefused',
      'SOCKSReply.TTLExpired',
      'SOCKSReply.CommandNotSupported',
      'SOCKSReply.AddressTypeNotSupported'
    ][_value];
  }
}

class SOCKSRequest {
  final int version = 0x05;
  final SOCKSCommand command;
  final SOCKSAddressType addressType;
  final Uint8List address;
  final int port;

  String getAddressString() {
    if (addressType == SOCKSAddressType.Domain) {
      return AsciiDecoder().convert(address);
    } else if (addressType == SOCKSAddressType.IPv4) {
      return address.join(".");
    } else if (addressType == SOCKSAddressType.IPv6) {
      var ret = List<String>();
      for (var x = 0; x < address.length; x += 2) {
        ret.add("${address[x].toRadixString(16).padLeft(2, "0")}${address[x + 1].toRadixString(16).padLeft(2, "0")}");
      }
      return ret.join(":");
    }
    return null;
  }

  SOCKSRequest({
    this.command,
    this.addressType,
    this.address,
    this.port,
  });
}

class SOCKSSocket {
  List<AuthMethods> _auth;
  RawSocket _sock;

  StreamSubscription<RawSocketEvent> _sockSub;
  SOCKSState _state;
  SOCKSRequest _request;

  final StreamController<SOCKSState> _stateStream = StreamController<SOCKSState>.broadcast();

  SOCKSState get state => _state;
  Stream<SOCKSState> get stateStream => _stateStream?.stream;

  /// Waits for state to change to [SOCKSState.Connected]
  /// If the connection request returns an error from the
  /// socks server it will be thrown as an exception in the stream
  ///
  ///
  Future<SOCKSState> get _waitForConnect => stateStream.firstWhere((a) => a == SOCKSState.Connected);

  SOCKSSocket(
    RawSocket socket, {
    List<AuthMethods> auth = const [AuthMethods.NoAuth],
  }) {
    _sock = socket;
    _auth = auth;
    _setState(SOCKSState.Starting);
  }

  void _setState(SOCKSState ns) {
    _state = ns;
    _stateStream.add(ns);
  }

  /// Issue connect command to proxy
  ///
  Future connect(String domain) async {
    final ds = domain.split(':');
    assert(ds.length == 2, "Domain must contain port, example.com:80");

    _request = SOCKSRequest(
      command: SOCKSCommand.Connect,
      addressType: SOCKSAddressType.Domain,
      address: AsciiEncoder().convert(ds[0]).sublist(0, ds[0].length),
      port: int.tryParse(ds[1]) ?? 80,
    );
    await _start();
    await _waitForConnect;
  }

  Future connectIp(InternetAddress ip, int port) async {
    _request = SOCKSRequest(
      command: SOCKSCommand.Connect,
      addressType: ip.type == InternetAddressType.IPv4 ? SOCKSAddressType.IPv4 : SOCKSAddressType.IPv6,
      address: ip.rawAddress,
      port: port,
    );
    await _start();
    await _waitForConnect;
  }

  Future close({bool keepOpen = true}) async {
    await _stateStream.close();
    if (!keepOpen) {
      await _sock.close();
    }
  }

  Future _start() async {
    // send auth methods
    _setState(SOCKSState.Auth);
    print(">> Version: 5, AuthMethods: $_auth");
    _sock.write([
      0x05,
      _auth.length,
      ..._auth.map((v) => v._value),
    ]);

    _sockSub = _sock.listen((RawSocketEvent ev) {
      switch (ev) {
        case RawSocketEvent.read:
          {
            final have = _sock.available();
            final data = _sock.read(have);
            _handleRead(data);
            break;
          }
        case RawSocketEvent.closed:
          {
            _sockSub.cancel();
            break;
          }
      }
    });
  }

  void _handleRead(Uint8List data) async {
    if (state == SOCKSState.Auth) {
      if (data.length == 2) {
        final version = data[0];
        final auth = AuthMethods._(data[1]);

        print("<< Version: $version, Auth: $auth");

        _setState(SOCKSState.RequestReady);
        _writeRequest(_request);
      } else {
        throw "Expected 2 bytes";
      }
    } else if (_state == SOCKSState.RequestReady) {
      if (data.length >= 10) {
        final version = data[0];
        final reply = SOCKSReply._(data[1]);
        //data[2] reserved
        final addrType = SOCKSAddressType._(data[3]);
        Uint8List addr;
        var port = 0;

        if (addrType == SOCKSAddressType.Domain) {
          final len = data[4];
          addr = data.sublist(5, 5 + len);
          port = data[5 + len] << 8 | data[6 + len];
        } else if (addrType == SOCKSAddressType.IPv4) {
          addr = data.sublist(5, 9);
          port = data[9] << 8 | data[10];
        } else if (addrType == SOCKSAddressType.IPv6) {
          addr = data.sublist(5, 21);
          port = data[21] << 8 | data[22];
        }

        print("<< Version: $version, Reply: $reply, AddrType: $addrType, Addr: $addr, Port: $port");
        if (reply._value == SOCKSReply.Success._value) {
          _setState(SOCKSState.Connected);
          _sockSub.cancel(); // dont listen anymore we are connected now
        } else {
          throw reply;
        }
      } else {
        throw "Expected 10 bytes";
      }
    }
  }

  void _writeRequest(SOCKSRequest req) {
    if (_state == SOCKSState.RequestReady) {
      final data = [
        req.version,
        req.command._value,
        0x00,
        req.addressType._value,
        if (req.addressType == SOCKSAddressType.Domain) req.address.lengthInBytes,
        ...req.address,
        req.port >> 8,
        req.port & 0xF0,
      ];
      print(data);
      print(
          ">> Version: ${req.version}, Command: ${req.command}, AddrType: ${req.addressType}, Addr: ${req.getAddressString()}, Port: ${req.port}");
      _sock.write(data);
    } else {
      throw "Must be in RequestReady state, current state $_state";
    }
  }
}
