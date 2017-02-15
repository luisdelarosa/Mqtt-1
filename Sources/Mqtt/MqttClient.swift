//
//  MqttClient.swift
//  Mqtt
//
//  Created by Heee on 16/1/18.
//  Copyright © 2016年 jianbo. All rights reserved.
//

import Socks
import Foundation

public protocol MqttClientDelegate {
    
    func mqtt(_ mqtt: MqttClient, didConnect address: String)
    
    func mqtt(_ mqtt: MqttClient, didPublish packet: PublishPacket)
    
    func mqtt(_ mqtt: MqttClient, didRecvMessage packet: PublishPacket)
    
    func mqtt(_ mqtt: MqttClient, didSubscribe result: [String: SubsAckReturnCode])
    
    func mqtt(_ mqtt: MqttClient, didUnsubscribe topics: [String])
    
    func mqtt(_ mqtt: MqttClient, didDisconnect error: Error?)
    
    func mqtt(_ mqtt: MqttClient, didRecvPingresp packet: PingRespPacket)
}

// 扩展协议具有默认实现.
// 当 `协议实现者` 实现该协议后, 实现了该方法. 
// 那么调用者, 调用该方法时是调用的哪个实现？
//extension MqttClientDelegate {
//    public func mqtt(_ mqtt: MqttClient, didRecvPingresp packet: PingRespPacket) {}
//}

/// client session state
public enum SessionState: Int {
    
    /// connack not equal .accept
    case denied = -1
    
    /// `MqttClient` class has init
    case initialization
    
    /// executing connect method, waiting connack packet
    case connecting
    
    /// receive .accept of connack
    case connected
    
    /// executed disconnect success, session end
    case disconnected
}

public enum ClientError: Error {
    
    case aleadryConnected
    
    case aleadryConnecting
    
    case hasDisconnected
    
    case notConnected
}

// TODO: 
//  1. 再被远端断开连接后, 需要及时通知程序本身, 及时改变 client 状态, 以及返回码
//  2. 
//
public final class MqttClient {
    
    private var _packetId: UInt16 = 0
    
    public var delegate: MqttClientDelegate?
    
    public fileprivate(set) var sessionState: SessionState {
        didSet {
            DDLogInfo("mqtt client session state did change to [\(sessionState)]")
        }
    }
    
    public fileprivate(set) var clientId: String
    /**
     When a Client reconnects with CleanSession set to 0, both the Client and Server MUST re-send any
     unacknowledged PUBLISH Packets (where QoS > 0) and PUBREL Packets using their original Packet
     Idenitifiers
     */
    public fileprivate(set) var cleanSession: Bool
    
    public fileprivate(set) var keepAlive: UInt16
    
    public fileprivate(set) var username: String?
    
    public fileprivate(set) var password: String?
    
    var willMessage: PublishPacket?
    
    fileprivate var session: Session?

    var mqttQueue: DispatchQueue
    
    var delegateQueue: DispatchQueue
    
    var stateLock: NSLock
    
    var timer: Timer?

    public init(clientId: String,
                cleanSession: Bool,
                keepAlive: UInt16,
                username: String?,
                password: String?,
                willMessage: PublishPacket?
        ) {
        self.clientId     = clientId
        self.cleanSession = cleanSession
        self.keepAlive    = keepAlive
        self.username     = username
        self.password     = password
        self.willMessage  = willMessage
        self.stateLock    = NSLock()
        self.mqttQueue    = DispatchQueue(label: "com.mqtt.client")
        self.delegateQueue = DispatchQueue.main
        
        sessionState = .initialization
    }
    
    deinit {
        DDLogVerbose("MqttClient deinit")
    }
    
    fileprivate var nextPacketId: UInt16 {
        if _packetId + 1 >= UInt16.max {
            _packetId = 0
        }
        _packetId += 1
        return _packetId
    }
    
    fileprivate func sessionSend(packet: Packet) throws {
        guard let session = session else {
            throw ClientError.notConnected
        }
        guard sessionState == .connected else {
            throw ClientError.notConnected
        }
        
        session.send(packet: packet)
    }
}

// MARK: convenience init
extension MqttClient {
    
    public convenience init(clientId: String) {
        self.init(clientId: clientId, cleanSession: false, keepAlive: 60, username: nil, password: nil, willMessage: nil)
    }
    
    public convenience init(clientId: String, cleanSession: Bool) {
        self.init(clientId: clientId, cleanSession: cleanSession, keepAlive: 60, username: nil, password: nil, willMessage: nil)
    }
    
    public convenience init(clientId: String, cleanSession: Bool, keepAlive: UInt16) {
        self.init(clientId: clientId, cleanSession: cleanSession, keepAlive: keepAlive, username: nil, password: nil, willMessage: nil)
    }
    
    
}

// MARK: MQTT method
extension MqttClient {
    
    /**
     
     - parameter port: TCP ports 8883 and 1883 are registered with IANA for MQTT TLS and non TLS communication respectively.
     */
    public func connect(host: String, port: UInt16 = 1883) throws {
        stateLock.lock()
        
        guard sessionState != .connected else {
            stateLock.unlock()
            throw ClientError.aleadryConnected
        }
        
        guard sessionState != .connecting else {
            stateLock.unlock()
            throw ClientError.aleadryConnecting
        }
        
        defer {
            sessionState = .connecting
            stateLock.unlock()
        }
        
        session = Session(host: host, port: port, del: self)
        
        // send connect packet
        var packet = ConnectPacket(clientId: clientId)
        
        packet.username = username
        packet.password = password
        packet.cleanSession = cleanSession
        packet.keepAlive = keepAlive
        session?.connect(packet: packet)
    }
    
    public func publish(topic: String, payload: [UInt8], qos: Qos = .qos1) throws {
        let packet = PublishPacket(packetId: nextPacketId, topic: topic, payload: payload, qos: qos)
        
        try sessionSend(packet: packet)
    }
    
    public func subscribe(topic: String, qos: Qos = .qos1) throws {
        var packet = SubscribePacket(packetId: nextPacketId)
        
        packet.topics.append((topic, qos))
        
        try sessionSend(packet: packet)
    }
    
    public func unsubscribe(topics: [String]) throws {
        var packet = UnsubscribePacket(packetId: nextPacketId)
        packet.topics = topics
        
        try sessionSend(packet: packet)
    }
    
    public func ping() throws {
        let packet = PingReqPacket()
        
        try sessionSend(packet: packet)
    }
    
    // FIXME: disconnect 时应该 回调一个 error = nil 的结果
    public func disconnect() throws {
        guard sessionState == .connected else {
            return
        }
        stateLock.lock()
        defer {
            sessionState = .disconnected
            stateLock.unlock()
        }
        let packet = DisconnectPacket()
        try sessionSend(packet: packet)
    }
}

// MARK: Public Helper Method
extension MqttClient {
    
    public func publish(topic: String, payload: String, qos: Qos = .qos1) throws {
        try publish(topic: topic, payload: payload.toBytes(), qos: qos)
    }
}

// MARK: - Private helper method
extension MqttClient {
    
    fileprivate func startHeartbeatTimer() {
        if timer != nil {
            timer?.invalidate()
            timer = nil
        }
        
        timer = Timer(timeInterval: Double(keepAlive), target: self, selector: #selector(_heartbeatTimerArrive), userInfo: nil, repeats: true)
        
        RunLoop.main.add(timer!, forMode: .commonModes)
    }
    
    fileprivate func stopHeartbeat() {
        timer?.invalidate()
        timer = nil
    }
    
    @objc private func _heartbeatTimerArrive() {
        let ping = PingReqPacket()
        try? sessionSend(packet: ping)
    }
}


extension MqttClient: SessionDelegate {
    
    func session(_ session: Session, didRecvPong: PingRespPacket) {
        DDLogInfo("session did recv pong")
    }
    
    func session(_ session: Session, didConnect address: String) {
        DDLogInfo("session did connect \(address)")
        
        sessionState = .connected
        
        startHeartbeatTimer()
        
        delegateQueue.async { [weak self] in
            guard let weakSelf = self else { return }
            weakSelf.delegate?.mqtt(weakSelf, didConnect: address)
        }
    }

    func session(_ session: Session, didRecvPublish packet: PublishPacket) {
        DDLogInfo("session did recv publish \(packet)")
        
        delegateQueue.async { [weak self] in
            guard let weakSelf = self else { return }
            weakSelf.delegate?.mqtt(weakSelf, didRecvMessage: packet)
        }
    }
    
    func session(_ session: Session, didPublish publish: PublishPacket) {
        DDLogInfo("session did send publish \(publish)")
        
        delegateQueue.async { [weak self] in
            guard let weakSelf = self else { return }
            weakSelf.delegate?.mqtt(weakSelf, didPublish: publish)
        }
    }
    
    func session(_ session: Session, didSend packet: Packet) {
        DDLogVerbose("session did send packet \(packet)")
        
    }
    
    func session(_ session: Session, didSubscribe topics: [String : SubsAckReturnCode]) {
        DDLogInfo("session did subscribe topics \(topics)")
        
        delegateQueue.async { [weak self] in
            guard let weakSelf = self else { return }
            weakSelf.delegate?.mqtt(weakSelf, didSubscribe: topics)
        }
    }
    
    func session(_ session: Session, didUnsubscribe topics: [String]) {
        DDLogInfo("session did unsubscirbe topics \(topics)")
        
        delegateQueue.async { [weak self] in
            guard let weakSelf = self else { return }
            weakSelf.delegate?.mqtt(weakSelf, didUnsubscribe: topics)
        }
    }
    
    func session(_ session: Session, didDisconnect error: Error?) {
        DDLogInfo("session did disconnect error: \(error)")
        
        stopHeartbeat()
        self.session = nil
        sessionState = .disconnected
        delegateQueue.async { [weak self] in
            guard let weakSelf = self else { return }
            weakSelf.delegate?.mqtt(weakSelf, didDisconnect: error)
        }
    }
}
