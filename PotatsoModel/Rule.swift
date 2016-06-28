//
//  Rule.swift
//  Potatso
//
//  Created by LEI on 4/6/16.
//  Copyright © 2016 TouchingApp. All rights reserved.
//

import RealmSwift
import PotatsoBase

private let ruleValueKey = "value";
private let ruleActionKey = "action";

public enum RuleType: String {
    case URLMatch = "URL-MATCH"
    case URL = "URL"
    case Domain = "DOMAIN"
    case DomainMatch = "DOMAIN-MATCH"
    case DomainSuffix = "DOMAIN-SUFFIX"
    case GeoIP = "GEOIP"
    case IPCIDR = "IP-CIDR"
}

extension RuleType {
    
    public static func fromInt(intValue: Int) -> RuleType? {
        switch intValue {
        case 1:
            return .Domain
        case 2:
            return .DomainSuffix
        case 3:
            return .DomainMatch
        case 4:
            return .URL
        case 5:
            return .URLMatch
        case 6:
            return .GeoIP
        case 7:
            return .IPCIDR
        default:
            return nil
        }
    }
    
}

extension RuleType: CustomStringConvertible {
    
    public var description: String {
        return rawValue
    }
    
}

public enum RuleAction: String {
    case Direct = "DIRECT"
    case Reject = "REJECT"
    case Proxy = "PROXY"
}

extension RuleAction {
    
    public static func fromInt(intValue: Int) -> RuleAction? {
        switch intValue {
        case 1:
            return .Direct
        case 2:
            return .Reject
        case 3:
            return .Proxy
        default:
            return nil
        }
    }
    
}

extension RuleAction: CustomStringConvertible {
    
    public var description: String {
        return rawValue
    }
    
}

public enum RuleError: ErrorType {
    case InvalidRule(String)
}

extension RuleError: CustomStringConvertible {
    
    public var description: String {
        switch self {
        case .InvalidRule(let rule):
            return "Invalid rule - \(rule)"
        }
    }
    
}

public final class Rule: BaseModel {
    
    public dynamic var typeRaw = ""
    public dynamic var content = ""
    public dynamic var order = 0
    public let rulesets = LinkingObjects(fromType: RuleSet.self, property: "rules")

}

extension Rule {
    
    public var type : RuleType {
        get {
            return RuleType(rawValue: typeRaw) ?? .URL
        }
        set(v) {
            typeRaw = v.rawValue
        }
    }
    
    public var action : RuleAction {
        let json = content.jsonDictionary()
        if let raw = json?[ruleActionKey] as? String {
            return RuleAction(rawValue: raw) ?? .Proxy
        }
        return .Proxy
    }
    
    public var value : String {
        let json = content.jsonDictionary()
        return json?[ruleValueKey] as? String ?? ""
    }

    public var pattern: String {
        switch type {
        case .DomainMatch:
            return "*\(value)*"
        case .DomainSuffix:
            return ".\(value)/"
        default:
            return value
        }
    }
}

extension Rule {
    
    public convenience init(str: String) throws {
        self.init()
        var ruleStr = str.stringByReplacingOccurrencesOfString("\t", withString: "")
        ruleStr = ruleStr.stringByReplacingOccurrencesOfString(" ", withString: "")
        let parts = ruleStr.componentsSeparatedByString(",")
        guard parts.count >= 3 else {
            throw RuleError.InvalidRule(str)
        }
        let actionStr = parts[2].uppercaseString
        let typeStr = parts[0].uppercaseString
        let value = parts[1]
        guard let type = RuleType(rawValue: typeStr), action = RuleAction(rawValue: actionStr) where value.characters.count > 0 else {
            throw RuleError.InvalidRule(str)
        }
        update(type, action: action, value: value)
    }
    
    public convenience init(type: RuleType, action: RuleAction, value: String) {
        self.init()
        update(type, action: action, value: value)
    }
    
    public func update(type: RuleType, action: RuleAction, value: String) {
        self.type = type
        self.content = [ruleActionKey: action.rawValue, ruleValueKey: value].jsonString() ?? ""
    }
    public override var description: String {
        return "\(type), \(value), \(action)"
    }
}


public func ==(lhs: Rule, rhs: Rule) -> Bool {
    return lhs.uuid == rhs.uuid
}