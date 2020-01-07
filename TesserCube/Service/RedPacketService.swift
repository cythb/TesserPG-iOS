//
//  RedPacketService.swift
//  TesserCube
//
//  Created by Cirno MainasuK on 2019-11-25.
//  Copyright © 2019 Sujitech. All rights reserved.
//

import os
import Foundation
import RealmSwift
import RxSwift
import BigInt
import Web3

private enum SchemaVersions: UInt64 {
    case version_1 = 1
    case version_2_rc1 = 4
    case version_2_rc2 = 5
    case version_2_rc3 = 8
    
    static let currentVersion: SchemaVersions = .version_2_rc3
}

final class RedPacketService {
    
    let disposeBag = DisposeBag()
    
    // Global observable queue:
    // Reuse sequence if shared observable object if already in queue
    // ANd also subscribe in service when observable created to prevent task canceled
    var createResultQueue: [RedPacket.ID: Observable<CreationSuccess>] = [:]
    var updateCreateResultQueue: [RedPacket.ID: Observable<CreationSuccess>] = [:]
    var checkAvailabilityQueue: [RedPacket.ID: Observable<RedPacketAvailability>] = [:]
    var claimQueue: [RedPacket.ID: Observable<TransactionHash>] = [:]
    var claimResultQueue: [RedPacket.ID: Observable<ClaimSuccess>] = [:]
    var updateClaimResultQueue: [RedPacket.ID: Observable<ClaimSuccess>] = [:]
    var refundQueue: [RedPacket.ID: Observable<TransactionHash>] = [:]
    var refundResultQueue: [RedPacket.ID: Observable<RefundSuccess>] = [:]
    var updateRefundResultQueue: [RedPacket.ID: Observable<RefundSuccess>] = [:]
    
    // per packet. 0.002025 ETH
    public static var redPacketMinAmount: Decimal {
        return Decimal(0.002025)
    }
    
    // per packet. 0.002025 ETH
    public static var redPacketMinAmountInWei: BigUInt {
        return 2025000.gwei
    }
    
    public static let redPacketContractABIData: Data = {
        let path = Bundle(for: WalletService.self).path(forResource: "redpacket", ofType: "json")
        return try! Data(contentsOf: URL(fileURLWithPath: path!))
    }()
    
    public static var redPacketContractByteCode: EthereumData = {
        let path = Bundle(for: WalletService.self).path(forResource: "redpacket", ofType: "bin")
        let bytesString = try! String(contentsOfFile: path!)
        return try! EthereumData(ethereumValue: bytesString.trimmingCharacters(in: .whitespacesAndNewlines))
    }()

    public static func redPacketContract(for address: EthereumAddress?, web3: Web3) throws -> DynamicContract {
        let contractABIData = redPacketContractABIData
        do {
            return try web3.eth.Contract(json: contractABIData, abiKey: nil, address: address)
        } catch {
            throw Error.internal("cannot initialize contract")
        }
    }
    
    static var realmConfiguration: Realm.Configuration {
        var config = Realm.Configuration()
        
        let realmName = "RedPacket_v2"
        config.fileURL = TCDBManager.dbDirectoryUrl.appendingPathComponent("\(realmName).realm")
        config.objectTypes = [RedPacket.self]
        
        // setup migration
        let schemeVersion: UInt64 = SchemaVersions.currentVersion.rawValue
        config.schemaVersion = schemeVersion
        config.migrationBlock = { migration, oldSchemeVersion in
            if oldSchemeVersion < SchemaVersions.version_2_rc3.rawValue {
                // add network property
                migration.enumerateObjects(ofType: RedPacket.className()) { old, new in
                    
                    new?["_network"] = RedPacketNetwork.rinkeby.rawValue
                }
            }
            
            if oldSchemeVersion < SchemaVersions.version_2_rc2.rawValue {
                // auto migrate
            }
            
            if oldSchemeVersion < SchemaVersions.version_2_rc1.rawValue {
                // auto migrate
            }
        }
        
        return config
    }
    
    static func realm() throws -> Realm {
        let config = RedPacketService.realmConfiguration
    
        try? FileManager.default.createDirectory(at: config.fileURL!.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: nil)
        
        return try Realm(configuration: config)
    }
    
    // MARK: - Singleton
    public static let shared = RedPacketService()
    
    private init() {
        _ = try? RedPacketService.realm()
    }

}

extension RedPacketService {
    
    /*
    static func validate(message: Message) -> Bool {
        let rawMessage = message.rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return rawMessage.hasPrefix("-----BEGIN RED PACKET-----") && rawMessage.hasSuffix("-----END RED PACKET-----")
    }
     */
    
    /*
    static func contractAddress(for message: Message) -> String? {
        guard validate(message: message) else {
            return nil
        }
        
        let scanner = Scanner(string: message.rawMessage.trimmingCharacters(in: .whitespacesAndNewlines))
        scanner.charactersToBeSkipped = nil
        // Jump to begin
        scanner.scanUpTo("-----BEGIN RED PACKET-----", into: nil)
        // Read -----BEGIN RED PACKET-----\r\n
        scanner.scanUpToCharacters(from: .newlines, into: nil)
        scanner.scanCharacters(from: .newlines, into: nil)
        // Read [fingerprint]:[userID]
        scanner.scanUpToCharacters(from: .newlines, into: nil)
        scanner.scanCharacters(from: .newlines, into: nil)
        
        var contractAddress: NSString?
        scanner.scanUpToCharacters(from: .newlines, into: &contractAddress)
        
        return contractAddress as String?
    }
     */
    
    /*
    static func userID(for message: Message) -> String? {
        guard validate(message: message) else {
            return nil
        }
        
        let scanner = Scanner(string: message.rawMessage.trimmingCharacters(in: .whitespacesAndNewlines))
        scanner.charactersToBeSkipped = nil
        scanner.scanUpTo(":", into: nil)
        // Read user id
        var userID: NSString?
        scanner.scanUpToCharacters(from: .newlines, into: &userID)
        
        return userID as String?
    }
     */
    
    /*
    static func uuids(for message: Message) -> [String] {
        guard validate(message: message) else {
            return []
        }
        
        let scanner = Scanner(string: message.rawMessage.trimmingCharacters(in: .whitespacesAndNewlines))
        scanner.charactersToBeSkipped = nil
        // Jump to begin
        scanner.scanUpTo("-----BEGIN RED PACKET-----", into: nil)
        // Read -----BEGIN RED PACKET-----\r\n
        scanner.scanUpToCharacters(from: .newlines, into: nil)
        scanner.scanCharacters(from: .newlines, into: nil)
        // Read [fingerprint]:[userID]
        scanner.scanUpToCharacters(from: .newlines, into: nil)
        scanner.scanCharacters(from: .newlines, into: nil)
        // Read contract address
        scanner.scanUpToCharacters(from: .newlines, into: nil)
        scanner.scanCharacters(from: .newlines, into: nil)
        
        var uuids: NSString?
        scanner.scanUpTo("-----END RED PACKET-----", into: &uuids)
        
        guard let uuidsString = uuids?.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n") else {
            return []
        }
        
        return uuidsString as [String]
    }
     */
    
}

extension RedPacketService {
    
}