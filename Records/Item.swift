//
//  Item.swift
//  Records
//
//  Created by Shuhei Matsuoka on 2026/10/18.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
