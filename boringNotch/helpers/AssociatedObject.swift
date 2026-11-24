//
//  AssociatedObject.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-05.
//

import Foundation
import ObjectiveC


/// Lightweight helper for Objective-C associated objects.
public struct AssociatedObject<Value: AnyObject> {
    private let keyObject = UniqueKey()
    private let policy: objc_AssociationPolicy

    private var key: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(keyObject).toOpaque())
    }

    public init(_ policy: objc_AssociationPolicy = .OBJC_ASSOCIATION_RETAIN_NONATOMIC) {
        self.policy = policy
    }

    private final class UniqueKey: @unchecked Sendable {}

    public subscript<Owner: AnyObject>(_ owner: Owner) -> Value? {
        get { objc_getAssociatedObject(owner, key) as? Value }
        nonmutating set { objc_setAssociatedObject(owner, key, newValue, policy) }
    }
}

extension AssociatedObject: @unchecked Sendable where Value: Sendable {}
