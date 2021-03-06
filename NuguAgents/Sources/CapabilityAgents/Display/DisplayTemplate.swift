//
//  DisplayTemplate.swift
//  NuguAgents
//
//  Created by MinChul Lee on 17/05/2019.
//  Copyright (c) 2019 SK Telecom Co., Ltd. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation

import NuguCore

public struct DisplayTemplate {
    public let type: String
    public let payload: Data
    public let templateId: String
    public let dialogRequestId: String
    public let template: Payload
    
    init(
        type: String,
        payload: Data,
        templateId: String,
        dialogRequestId: String,
        template: Payload
    ) {
        self.type = type
        self.payload = payload
        self.templateId = templateId
        self.dialogRequestId = dialogRequestId
        self.template = template
    }
    
    public struct Payload {
        public let token: String
        public let playServiceId: String
        public let playStackControl: PlayStackControl?
        public let duration: Duration?
        public let focusable: Bool?
        public let contextLayer: PlaySyncProperty.LayerType
        public var playSyncProperty: PlaySyncProperty {
            PlaySyncProperty(layerType: contextLayer, contextType: .display)
        }
        
        public enum Duration: String, Decodable {
            case short = "SHORT"
            case mid = "MID"
            case long = "LONG"
            case longest = "LONGEST"
        }
    }
}

// MARK: - DisplayTemplate.Payload: Decodable

extension DisplayTemplate.Payload: Decodable {
    enum CodingKeys: String, CodingKey {
        case token
        case playServiceId
        case playStackControl
        case duration
        case focusable
        case contextLayer
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        token = try container.decode(String.self, forKey: .token)
        playServiceId = try container.decode(String.self, forKey: .playServiceId)
        playStackControl = try? container.decode(PlayStackControl.self, forKey: .playStackControl)
        duration = try? container.decode(Duration.self, forKey: .duration)
        focusable = try? container.decodeIfPresent(Bool.self, forKey: .focusable)
        contextLayer = (try? container.decode(PlaySyncProperty.LayerType.self, forKey: .contextLayer)) ?? .info
    }
}

extension DisplayTemplate.Payload.Duration {
    public var time: TimeIntervallic {
        switch self {
        case .short: return NuguTimeInterval(seconds: 7)
        case .mid: return NuguTimeInterval(seconds: 15)
        case .long: return NuguTimeInterval(seconds: 30)
        case .longest: return NuguTimeInterval(seconds: 60 * 10)
        }
    }
}
