//! This file defines several variants of bit sets.  A bit set
//! is a densely stored set of integers with a known maximum,
//! in which each integer gets a single bit.  Bit sets have very
//! fast presence checks, update operations, and union and intersection
//! operations.  However, if the number of possible items is very
//! large and the number of actual items in a given set is usually
//! small, they may be less memory efficient than an array set.
//!
//! There are five variants defined here:
//!
//! IntegerBitSet:
//!   A bit set with static size, which is backed by a single integer.
//!   This set is good for sets with a small size, but may generate
//!   inefficient code for larger sets, especially in debug mode.
//!
//! ArrayBitSet:
//!   A bit set with static size, which is backed by an array of usize.
//!   This set is good for sets with a larger size, but may use
//!   more bytes than necessary if your set is small.
//!
//! StaticBitSet:
//!   Picks either IntegerBitSet or ArrayBitSet depending on the requested
//!   size.  The interfaces of these two types match exactly, except for fields.
//!
//! DynamicBitSet:
//!   A bit set with runtime-known size, backed by an allocated slice
//!   of usize.
//!
//! DynamicBitSetUnmanaged:
//!   A variant of DynamicBitSet which does not store a pointer to its
//!   allocator, in order to save space.

const std = @import("std.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

/// Returns the optimal static bit set type for the specified number
/// of elements: either `IntegerBitSet` or `ArrayBitSet`,
/// both of which fulfill the same interface.
/// The returned type will perform no allocations,
/// can be copied by value, and does not require deinitialization.
pub fn StaticBitSet(comptime size: usize) type {
    if (size <= @bitSizeOf(usize)) {
        return IntegerBitSet(size);
    } else {
        return ArrayBitSet(usize, size);
    }
}

/// A bit set with static size, which is backed by a single integer.
/// This set is good for sets with a small size, but may generate
/// inefficient code for larger sets, especially in debug mode.
pub fn IntegerBitSet(comptime size: u16) type {
    return packed struct {
        const Self = @This();

        // TODO: Make this a comptime field once those are fixed
        /// The number of items in this bit set
        pub const bit_length: usize = size;

        /// The integer type used to represent a mask in this bit set
        pub const MaskInt = std.meta.Int(.unsigned, size);

        /// The integer type used to shift a mask in this bit set
        pub const ShiftInt = std.math.Log2Int(MaskInt);

        /// The bit mask, as a single integer
        mask: MaskInt,

        /// Creates a bit set with no elements present.
        pub fn initEmpty() Self {
            return .{ .mask = 0 };
        }

        /// Creates a bit set with all elements present.
        pub fn initFull() Self {
            return .{ .mask = ~@as(MaskInt, 0) };
        }

        /// Returns the number of bits in this bit set
        pub inline fn capacity(self: Self) usize {
            _ = self;
            return bit_length;
        }

        /// Returns true if the bit at the specified index
        /// is present in the set, false otherwise.
        pub fn isSet(self: Self, index: usize) bool {
            assert(index < bit_length);
            return (self.mask & maskBit(index)) != 0;
        }

        /// Returns the total number of set bits in this bit set.
        pub fn count(self: Self) usize {
            return @popCount(self.mask);
        }

        /// Changes the value of the specified bit of the bit
        /// set to match the passed boolean.
        pub fn setValue(self: *Self, index: usize, value: bool) void {
            assert(index < bit_length);
            if (MaskInt == u0) return;
            const bit = maskBit(index);
            const new_bit = bit & std.math.boolMask(MaskInt, value);
            self.mask = (self.mask & ~bit) | new_bit;
        }

        /// Adds a specific bit to the bit set
        pub fn set(self: *Self, index: usize) void {
            assert(index < bit_length);
            self.mask |= maskBit(index);
        }

        /// Changes the value of all bits in the specified range to
        /// match the passed boolean.
        pub fn setRangeValue(self: *Self, range: Range, value: bool) void {
            assert(range.end <= bit_length);
            assert(range.start <= range.end);
            if (range.start == range.end) return;
            if (MaskInt == u0) return;

            const start_bit = @as(ShiftInt, @intCast(range.start));

            var mask = std.math.boolMask(MaskInt, true) << start_bit;
            if (range.end != bit_length) {
                const end_bit = @as(ShiftInt, @intCast(range.end));
                mask &= std.math.boolMask(MaskInt, true) >> @as(ShiftInt, @truncate(@as(usize, @bitSizeOf(MaskInt)) - @as(usize, end_bit)));
            }
            self.mask &= ~mask;

            mask = std.math.boolMask(MaskInt, value) << start_bit;
            if (range.end != bit_length) {
                const end_bit = @as(ShiftInt, @intCast(range.end));
                mask &= std.math.boolMask(MaskInt, value) >> @as(ShiftInt, @truncate(@as(usize, @bitSizeOf(MaskInt)) - @as(usize, end_bit)));
            }
            self.mask |= mask;
        }

        /// Removes a specific bit from the bit set
        pub fn unset(self: *Self, index: usize) void {
            assert(index < bit_length);
            // Workaround for #7953
            if (MaskInt == u0) return;
            self.mask &= ~maskBit(index);
        }

        /// Flips a specific bit in the bit set
        pub fn toggle(self: *Self, index: usize) void {
            assert(index < bit_length);
            self.mask ^= maskBit(index);
        }

        /// Flips all bits in this bit set which are present
        /// in the toggles bit set.
        pub fn toggleSet(self: *Self, toggles: Self) void {
            self.mask ^= toggles.mask;
        }

        /// Flips every bit in the bit set.
        pub fn toggleAll(self: *Self) void {
            self.mask = ~self.mask;
        }

        /// Performs a union of two bit sets, and stores the
        /// result in the first one.  Bits in the result are
        /// set if the corresponding bits were set in either input.
        pub fn setUnion(self: *Self, other: Self) void {
            self.mask |= other.mask;
        }

        /// Performs an intersection of two bit sets, and stores
        /// the result in the first one.  Bits in the result are
        /// set if the corresponding bits were set in both inputs.
        pub fn setIntersection(self: *Self, other: Self) void {
            self.mask &= other.mask;
        }

        /// Finds the index of the first set bit.
        /// If no bits are set, returns null.
        pub fn findFirstSet(self: Self) ?usize {
            const mask = self.mask;
            if (mask == 0) return null;
            return @ctz(mask);
        }

        /// Finds the index of the last set bit.
        /// If no bits are set, returns null.
        pub fn findLastSet(self: Self) ?usize {
            const mask = self.mask;
            if (mask == 0) return null;
            return bit_length - @clz(mask) - 1;
        }

        /// Finds the index of the first set bit, and unsets it.
        /// If no bits are set, returns null.
        pub fn toggleFirstSet(self: *Self) ?usize {
            const mask = self.mask;
            if (mask == 0) return null;
            const index = @ctz(mask);
            self.mask = mask & (mask - 1);
            return index;
        }

        /// Returns true iff every corresponding bit in both
        /// bit sets are the same.
        pub fn eql(self: Self, other: Self) bool {
            return bit_length == 0 or self.mask == other.mask;
        }

        /// Returns true iff the first bit set is the subset
        /// of the second one.
        pub fn subsetOf(self: Self, other: Self) bool {
            return self.intersectWith(other).eql(self);
        }

        /// Returns true iff the first bit set is the superset
        /// of the second one.
        pub fn supersetOf(self: Self, other: Self) bool {
            return other.subsetOf(self);
        }

        /// Returns the complement bit sets. Bits in the result
        /// are set if the corresponding bits were not set.
        pub fn complement(self: Self) Self {
            var result = self;
            result.toggleAll();
            return result;
        }

        /// Returns the union of two bit sets. Bits in the
        /// result are set if the corresponding bits were set
        /// in either input.
        pub fn unionWith(self: Self, other: Self) Self {
            var result = self;
            result.setUnion(other);
            return result;
        }

        /// Returns the intersection of two bit sets. Bits in
        /// the result are set if the corresponding bits were
        /// set in both inputs.
        pub fn intersectWith(self: Self, other: Self) Self {
            var result = self;
            result.setIntersection(other);
            return result;
        }

        /// Returns the xor of two bit sets. Bits in the
        /// result are set if the corresponding bits were
        /// not the same in both inputs.
        pub fn xorWith(self: Self, other: Self) Self {
            var result = self;
            result.toggleSet(other);
            return result;
        }

        /// Returns the difference of two bit sets. Bits in
        /// the result are set if set in the first but not
        /// set in the second set.
        pub fn differenceWith(self: Self, other: Self) Self {
            var result = self;
            result.setIntersection(other.complement());
            return result;
        }

        /// Iterates through the items in the set, according to the options.
        /// The default options (.{}) will iterate indices of set bits in
        /// ascending order.  Modifications to the underlying bit set may
        /// or may not be observed by the iterator.
        pub fn iterator(self: *const Self, comptime options: IteratorOptions) Iterator(options) {
            return .{
                .bits_remain = switch (options.kind) {
                    .set => self.mask,
                    .unset => ~self.mask,
                },
            };
        }

        pub fn Iterator(comptime options: IteratorOptions) type {
            return SingleWordIterator(options.direction);
        }

        fn SingleWordIterator(comptime direction: IteratorOptions.Direction) type {
            return struct {
                const IterSelf = @This();
                // all bits which have not yet been iterated over
                bits_remain: MaskInt,

                /// Returns the index of the next unvisited set bit
                /// in the bit set, in ascending order.
                pub fn next(self: *IterSelf) ?usize {
                    if (self.bits_remain == 0) return null;

                    switch (direction) {
                        .forward => {
                            const next_index = @ctz(self.bits_remain);
                            self.bits_remain &= self.bits_remain - 1;
                            return next_index;
                        },
                        .reverse => {
                            const leading_zeroes = @clz(self.bits_remain);
                            const top_bit = (@bitSizeOf(MaskInt) - 1) - leading_zeroes;
                            self.bits_remain &= (@as(MaskInt, 1) << @as(ShiftInt, @intCast(top_bit))) - 1;
                            return top_bit;
                        },
                    }
                }
            };
        }

        fn maskBit(index: usize) MaskInt {
            if (MaskInt == u0) return 0;
            return @as(MaskInt, 1) << @as(ShiftInt, @intCast(index));
        }
        fn boolMaskBit(index: usize, value: bool) MaskInt {
            if (MaskInt == u0) return 0;
            return @as(MaskInt, @intFromBool(value)) << @as(ShiftInt, @intCast(index));
        }
    };
}

/// A bit set with static size, which is backed by an array of usize.
/// This set is good for sets with a larger size, but may use
/// more bytes than necessary if your set is small.
pub fn ArrayBitSet(comptime MaskIntType: type, comptime size: usize) type {
    const mask_info: std.builtin.Type = @typeInfo(MaskIntType);

    // Make sure the mask int is indeed an int
    if (mask_info != .int) @compileError("ArrayBitSet can only operate on integer masks, but was passed " ++ @typeName(MaskIntType));

    // It must also be unsigned.
    if (mask_info.int.signedness != .unsigned) @compileError("ArrayBitSet requires an unsigned integer mask type, but was passed " ++ @typeName(MaskIntType));

    // And it must not be empty.
    if (MaskIntType == u0)
        @compileError("ArrayBitSet requires a sized integer for its mask int.  u0 does not work.");

    const byte_size = std.mem.byte_size_in_bits;

    // We use shift and truncate to decompose indices into mask indices and bit indices.
    // This operation requires that the mask has an exact power of two number of bits.
    if (!std.math.isPowerOfTwo(@bitSizeOf(MaskIntType))) {
        var desired_bits = std.math.ceilPowerOfTwoAssert(usize, @bitSizeOf(MaskIntType));
        if (desired_bits < byte_size) desired_bits = byte_size;
        const FixedMaskType = std.meta.Int(.unsigned, desired_bits);
        @compileError("ArrayBitSet was passed integer type " ++ @typeName(MaskIntType) ++
            ", which is not a power of two.  Please round this up to a power of two integer size (i.e. " ++ @typeName(FixedMaskType) ++ ").");
    }

    // Make sure the integer has no padding bits.
    // Those would be wasteful here and are probably a mistake by the user.
    // This case may be hit with small powers of two, like u4.
    if (@bitSizeOf(MaskIntType) != @sizeOf(MaskIntType) * byte_size) {
        var desired_bits = @sizeOf(MaskIntType) * byte_size;
        desired_bits = std.math.ceilPowerOfTwoAssert(usize, desired_bits);
        const FixedMaskType = std.meta.Int(.unsigned, desired_bits);
        @compileError("ArrayBitSet was passed integer type " ++ @typeName(MaskIntType) ++
            ", which contains padding bits.  Please round this up to an unpadded integer size (i.e. " ++ @typeName(FixedMaskType) ++ ").");
    }

    return extern struct {
        const Self = @This();

        // TODO: Make this a comptime field once those are fixed
        /// The number of items in this bit set
        pub const bit_length: usize = size;

        /// The integer type used to represent a mask in this bit set
        pub const MaskInt = MaskIntType;

        /// The integer type used to shift a mask in this bit set
        pub const ShiftInt = std.math.Log2Int(MaskInt);

        // bits in one mask
        const mask_len = @bitSizeOf(MaskInt);
        // total number of masks
        const num_masks = (size + mask_len - 1) / mask_len;
        // padding bits in the last mask (may be 0)
        const last_pad_bits = mask_len * num_masks - size;
        // Mask of valid bits in the last mask.
        // All functions will ensure that the invalid
        // bits in the last mask are zero.
        pub const last_item_mask = ~@as(MaskInt, 0) >> last_pad_bits;

        /// The bit masks, ordered with lower indices first.
        /// Padding bits at the end are undefined.
        masks: [num_masks]MaskInt,

        /// Creates a bit set with no elements present.
        pub fn initEmpty() Self {
            return .{ .masks = [_]MaskInt{0} ** num_masks };
        }

        /// Creates a bit set with all elements present.
        pub fn initFull() Self {
            if (num_masks == 0) {
                return .{ .masks = .{} };
            } else {
                return .{ .masks = [_]MaskInt{~@as(MaskInt, 0)} ** (num_masks - 1) ++ [_]MaskInt{last_item_mask} };
            }
        }

        /// Returns the number of bits in this bit set
        pub inline fn capacity(self: Self) usize {
            _ = self;
            return bit_length;
        }

        /// Returns true if the bit at the specified index
        /// is present in the set, false otherwise.
        pub fn isSet(self: Self, index: usize) bool {
            assert(index < bit_length);
            if (num_masks == 0) return false; // doesn't compile in this case
            return (self.masks[maskIndex(index)] & maskBit(index)) != 0;
        }

        /// Returns the total number of set bits in this bit set.
        pub fn count(self: Self) usize {
            var total: usize = 0;
            for (self.masks) |mask| {
                total += @popCount(mask);
            }
            return total;
        }

        /// Changes the value of the specified bit of the bit
        /// set to match the passed boolean.
        pub fn setValue(self: *Self, index: usize, value: bool) void {
            assert(index < bit_length);
            if (num_masks == 0) return; // doesn't compile in this case
            const bit = maskBit(index);
            const mask_index = maskIndex(index);
            const new_bit = bit & std.math.boolMask(MaskInt, value);
            self.masks[mask_index] = (self.masks[mask_index] & ~bit) | new_bit;
        }

        /// Adds a specific bit to the bit set
        pub fn set(self: *Self, index: usize) void {
            assert(index < bit_length);
            if (num_masks == 0) return; // doesn't compile in this case
            self.masks[maskIndex(index)] |= maskBit(index);
        }

        /// Changes the value of all bits in the specified range to
        /// match the passed boolean.
        pub fn setRangeValue(self: *Self, range: Range, value: bool) void {
            assert(range.end <= bit_length);
            assert(range.start <= range.end);
            if (range.start == range.end) return;
            if (num_masks == 0) return;

            const start_mask_index = maskIndex(range.start);
            const start_bit = @as(ShiftInt, @truncate(range.start));

            const end_mask_index = maskIndex(range.end);
            const end_bit = @as(ShiftInt, @truncate(range.end));

            if (start_mask_index == end_mask_index) {
                var mask1 = std.math.boolMask(MaskInt, true) << start_bit;
                var mask2 = std.math.boolMask(MaskInt, true) >> (mask_len - 1) - (end_bit - 1);
                self.masks[start_mask_index] &= ~(mask1 & mask2);

                mask1 = std.math.boolMask(MaskInt, value) << start_bit;
                mask2 = std.math.boolMask(MaskInt, value) >> (mask_len - 1) - (end_bit - 1);
                self.masks[start_mask_index] |= mask1 & mask2;
            } else {
                var bulk_mask_index: usize = undefined;
                if (start_bit > 0) {
                    self.masks[start_mask_index] =
                        (self.masks[start_mask_index] & ~(std.math.boolMask(MaskInt, true) << start_bit)) |
                        (std.math.boolMask(MaskInt, value) << start_bit);
                    bulk_mask_index = start_mask_index + 1;
                } else {
                    bulk_mask_index = start_mask_index;
                }

                while (bulk_mask_index < end_mask_index) : (bulk_mask_index += 1) {
                    self.masks[bulk_mask_index] = std.math.boolMask(MaskInt, value);
                }

                if (end_bit > 0) {
                    self.masks[end_mask_index] =
                        (self.masks[end_mask_index] & (std.math.boolMask(MaskInt, true) << end_bit)) |
                        (std.math.boolMask(MaskInt, value) >> ((@bitSizeOf(MaskInt) - 1) - (end_bit - 1)));
                }
            }
        }

        /// Removes a specific bit from the bit set
        pub fn unset(self: *Self, index: usize) void {
            assert(index < bit_length);
            if (num_masks == 0) return; // doesn't compile in this case
            self.masks[maskIndex(index)] &= ~maskBit(index);
        }

        /// Flips a specific bit in the bit set
        pub fn toggle(self: *Self, index: usize) void {
            assert(index < bit_length);
            if (num_masks == 0) return; // doesn't compile in this case
            self.masks[maskIndex(index)] ^= maskBit(index);
        }

        /// Flips all bits in this bit set which are present
        /// in the toggles bit set.
        pub fn toggleSet(self: *Self, toggles: Self) void {
            for (&self.masks, 0..) |*mask, i| {
                mask.* ^= toggles.masks[i];
            }
        }

        /// Flips every bit in the bit set.
        pub fn toggleAll(self: *Self) void {
            for (&self.masks) |*mask| {
                mask.* = ~mask.*;
            }

            // Zero the padding bits
            if (num_masks > 0) {
                self.masks[num_masks - 1] &= last_item_mask;
            }
        }

        /// Performs a union of two bit sets, and stores the
        /// result in the first one.  Bits in the result are
        /// set if the corresponding bits were set in either input.
        pub fn setUnion(self: *Self, other: Self) void {
            for (&self.masks, 0..) |*mask, i| {
                mask.* |= other.masks[i];
            }
        }

        /// Performs an intersection of two bit sets, and stores
        /// the result in the first one.  Bits in the result are
        /// set if the corresponding bits were set in both inputs.
        pub fn setIntersection(self: *Self, other: Self) void {
            for (&self.masks, 0..) |*mask, i| {
                mask.* &= other.masks[i];
            }
        }

        /// Finds the index of the first set bit.
        /// If no bits are set, returns null.
        pub fn findFirstSet(self: Self) ?usize {
            var offset: usize = 0;
            const mask = for (self.masks) |mask| {
                if (mask != 0) break mask;
                offset += @bitSizeOf(MaskInt);
            } else return null;
            return offset + @ctz(mask);
        }

        /// Finds the index of the last set bit.
        /// If no bits are set, returns null.
        pub fn findLastSet(self: Self) ?usize {
            if (bit_length == 0) return null;
            const bs = @bitSizeOf(MaskInt);
            var len = bit_length / bs;
            if (bit_length % bs != 0) len += 1;
            var offset: usize = len * bs;
            var idx: usize = len - 1;
            while (self.masks[idx] == 0) : (idx -= 1) {
                offset -= bs;
                if (idx == 0) return null;
            }
            offset -= @clz(self.masks[idx]);
            offset -= 1;
            return offset;
        }

        /// Finds the index of the first set bit, and unsets it.
        /// If no bits are set, returns null.
        pub fn toggleFirstSet(self: *Self) ?usize {
            var offset: usize = 0;
            const mask = for (&self.masks) |*mask| {
                if (mask.* != 0) break mask;
                offset += @bitSizeOf(MaskInt);
            } else return null;
            const index = @ctz(mask.*);
            mask.* &= (mask.* - 1);
            return offset + index;
        }

        /// Returns true iff every corresponding bit in both
        /// bit sets are the same.
        pub fn eql(self: Self, other: Self) bool {
            var i: usize = 0;
            return while (i < num_masks) : (i += 1) {
                if (self.masks[i] != other.masks[i]) {
                    break false;
                }
            } else true;
        }

        /// Returns true iff the first bit set is the subset
        /// of the second one.
        pub fn subsetOf(self: Self, other: Self) bool {
            return self.intersectWith(other).eql(self);
        }

        /// Returns true iff the first bit set is the superset
        /// of the second one.
        pub fn supersetOf(self: Self, other: Self) bool {
            return other.subsetOf(self);
        }

        /// Returns the complement bit sets. Bits in the result
        /// are set if the corresponding bits were not set.
        pub fn complement(self: Self) Self {
            var result = self;
            result.toggleAll();
            return result;
        }

        /// Returns the union of two bit sets. Bits in the
        /// result are set if the corresponding bits were set
        /// in either input.
        pub fn unionWith(self: Self, other: Self) Self {
            var result = self;
            result.setUnion(other);
            return result;
        }

        /// Returns the intersection of two bit sets. Bits in
        /// the result are set if the corresponding bits were
        /// set in both inputs.
        pub fn intersectWith(self: Self, other: Self) Self {
            var result = self;
            result.setIntersection(other);
            return result;
        }

        /// Returns the xor of two bit sets. Bits in the
        /// result are set if the corresponding bits were
        /// not the same in both inputs.
        pub fn xorWith(self: Self, other: Self) Self {
            var result = self;
            result.toggleSet(other);
            return result;
        }

        /// Returns the difference of two bit sets. Bits in
        /// the result are set if set in the first but not
        /// set in the second set.
        pub fn differenceWith(self: Self, other: Self) Self {
            var result = self;
            result.setIntersection(other.complement());
            return result;
        }

        /// Iterates through the items in the set, according to the options.
        /// The default options (.{}) will iterate indices of set bits in
        /// ascending order.  Modifications to the underlying bit set may
        /// or may not be observed by the iterator.
        pub fn iterator(self: *const Self, comptime options: IteratorOptions) Iterator(options) {
            return Iterator(options).init(&self.masks, last_item_mask);
        }

        pub fn Iterator(comptime options: IteratorOptions) type {
            return BitSetIterator(MaskInt, options);
        }

        fn maskBit(index: usize) MaskInt {
            return @as(MaskInt, 1) << @as(ShiftInt, @truncate(index));
        }
        fn maskIndex(index: usize) usize {
            return index >> @bitSizeOf(ShiftInt);
        }
        fn boolMaskBit(index: usize, value: bool) MaskInt {
            return @as(MaskInt, @intFromBool(value)) << @as(ShiftInt, @intCast(index));
        }
    };
}

/// A bit set with runtime-known size, backed by an allocated slice
/// of usize.  The allocator must be tracked externally by the user.
pub const DynamicBitSetUnmanaged = struct {
    const Self = @This();

    /// The integer type used to represent a mask in this bit set
    pub const MaskInt = usize;

    /// The integer type used to shift a mask in this bit set
    pub const ShiftInt = std.math.Log2Int(MaskInt);

    /// The number of valid items in this bit set
    bit_length: usize = 0,

    /// The bit masks, ordered with lower indices first.
    /// Padding bits at the end must be zeroed.
    masks: [*]MaskInt = empty_masks_ptr,
    // This pointer is one usize after the actual allocation.
    // That slot holds the size of the true allocation, which
    // is needed by Zig's allocator interface in case a shrink
    // fails.

    // Don't modify this value.  Ideally it would go in const data so
    // modifications would cause a bus error, but the only way
    // to discard a const qualifier is through intFromPtr, which
    // cannot currently round trip at comptime.
    var empty_masks_data = [_]MaskInt{ 0, undefined };
    const empty_masks_ptr = empty_masks_data[1..2];

    /// Creates a bit set with no elements present.
    /// If bit_length is not zero, deinit must eventually be called.
    pub fn initEmpty(allocator: Allocator, bit_length: usize) !Self {
        var self = Self{};
        try self.resize(allocator, bit_length, false);
        return self;
    }

    /// Creates a bit set with all elements present.
    /// If bit_length is not zero, deinit must eventually be called.
    pub fn initFull(allocator: Allocator, bit_length: usize) !Self {
        var self = Self{};
        try self.resize(allocator, bit_length, true);
        return self;
    }

    /// Resizes to a new bit_length.  If the new length is larger
    /// than the old length, fills any added bits with `fill`.
    /// If new_len is not zero, deinit must eventually be called.
    pub fn resize(self: *@This(), allocator: Allocator, new_len: usize, fill: bool) !void {
        const old_len = self.bit_length;

        const old_masks = numMasks(old_len);
        const new_masks = numMasks(new_len);

        const old_allocation = (self.masks - 1)[0..(self.masks - 1)[0]];

        if (new_masks == 0) {
            assert(new_len == 0);
            allocator.free(old_allocation);
            self.masks = empty_masks_ptr;
            self.bit_length = 0;
            return;
        }

        if (old_allocation.len != new_masks + 1) realloc: {
            // If realloc fails, it may mean one of two things.
            // If we are growing, it means we are out of memory.
            // If we are shrinking, it means the allocator doesn't
            // want to move the allocation.  This means we need to
            // hold on to the extra 8 bytes required to be able to free
            // this allocation properly.
            const new_allocation = allocator.realloc(old_allocation, new_masks + 1) catch |err| {
                if (new_masks + 1 > old_allocation.len) return err;
                break :realloc;
            };

            new_allocation[0] = new_allocation.len;
            self.masks = new_allocation.ptr + 1;
        }

        // If we increased in size, we need to set any new bits
        // to the fill value.
        if (new_len > old_len) {
            // set the padding bits in the old last item to 1
            if (fill and old_masks > 0) {
                const old_padding_bits = old_masks * @bitSizeOf(MaskInt) - old_len;
                const old_mask = (~@as(MaskInt, 0)) >> @as(ShiftInt, @intCast(old_padding_bits));
                self.masks[old_masks - 1] |= ~old_mask;
            }

            // fill in any new masks
            if (new_masks > old_masks) {
                const fill_value = std.math.boolMask(MaskInt, fill);
                @memset(self.masks[old_masks..new_masks], fill_value);
            }
        }

        // Zero out the padding bits
        if (new_len > 0) {
            const padding_bits = new_masks * @bitSizeOf(MaskInt) - new_len;
            const last_item_mask = (~@as(MaskInt, 0)) >> @as(ShiftInt, @intCast(padding_bits));
            self.masks[new_masks - 1] &= last_item_mask;
        }

        // And finally, save the new length.
        self.bit_length = new_len;
    }

    /// Deinitializes the array and releases its memory.
    /// The passed allocator must be the same one used for
    /// init* or resize in the past.
    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.resize(allocator, 0, false) catch unreachable;
    }

    /// Creates a duplicate of this bit set, using the new allocator.
    pub fn clone(self: *const Self, new_allocator: Allocator) !Self {
        const num_masks = numMasks(self.bit_length);
        var copy = Self{};
        try copy.resize(new_allocator, self.bit_length, false);
        @memcpy(copy.masks[0..num_masks], self.masks[0..num_masks]);
        return copy;
    }

    /// Returns the number of bits in this bit set
    pub inline fn capacity(self: Self) usize {
        return self.bit_length;
    }

    /// Returns true if the bit at the specified index
    /// is present in the set, false otherwise.
    pub fn isSet(self: Self, index: usize) bool {
        assert(index < self.bit_length);
        return (self.masks[maskIndex(index)] & maskBit(index)) != 0;
    }

    /// Returns the total number of set bits in this bit set.
    pub fn count(self: Self) usize {
        const num_masks = (self.bit_length + (@bitSizeOf(MaskInt) - 1)) / @bitSizeOf(MaskInt);
        var total: usize = 0;
        for (self.masks[0..num_masks]) |mask| {
            // Note: This is where we depend on padding bits being zero
            total += @popCount(mask);
        }
        return total;
    }

    /// Changes the value of the specified bit of the bit
    /// set to match the passed boolean.
    pub fn setValue(self: *Self, index: usize, value: bool) void {
        assert(index < self.bit_length);
        const bit = maskBit(index);
        const mask_index = maskIndex(index);
        const new_bit = bit & std.math.boolMask(MaskInt, value);
        self.masks[mask_index] = (self.masks[mask_index] & ~bit) | new_bit;
    }

    /// Adds a specific bit to the bit set
    pub fn set(self: *Self, index: usize) void {
        assert(index < self.bit_length);
        self.masks[maskIndex(index)] |= maskBit(index);
    }

    /// Changes the value of all bits in the specified range to
    /// match the passed boolean.
    pub fn setRangeValue(self: *Self, range: Range, value: bool) void {
        assert(range.end <= self.bit_length);
        assert(range.start <= range.end);
        if (range.start == range.end) return;

        const start_mask_index = maskIndex(range.start);
        const start_bit = @as(ShiftInt, @truncate(range.start));

        const end_mask_index = maskIndex(range.end);
        const end_bit = @as(ShiftInt, @truncate(range.end));

        if (start_mask_index == end_mask_index) {
            var mask1 = std.math.boolMask(MaskInt, true) << start_bit;
            var mask2 = std.math.boolMask(MaskInt, true) >> (@bitSizeOf(MaskInt) - 1) - (end_bit - 1);
            self.masks[start_mask_index] &= ~(mask1 & mask2);

            mask1 = std.math.boolMask(MaskInt, value) << start_bit;
            mask2 = std.math.boolMask(MaskInt, value) >> (@bitSizeOf(MaskInt) - 1) - (end_bit - 1);
            self.masks[start_mask_index] |= mask1 & mask2;
        } else {
            var bulk_mask_index: usize = undefined;
            if (start_bit > 0) {
                self.masks[start_mask_index] =
                    (self.masks[start_mask_index] & ~(std.math.boolMask(MaskInt, true) << start_bit)) |
                    (std.math.boolMask(MaskInt, value) << start_bit);
                bulk_mask_index = start_mask_index + 1;
            } else {
                bulk_mask_index = start_mask_index;
            }

            while (bulk_mask_index < end_mask_index) : (bulk_mask_index += 1) {
                self.masks[bulk_mask_index] = std.math.boolMask(MaskInt, value);
            }

            if (end_bit > 0) {
                self.masks[end_mask_index] =
                    (self.masks[end_mask_index] & (std.math.boolMask(MaskInt, true) << end_bit)) |
                    (std.math.boolMask(MaskInt, value) >> ((@bitSizeOf(MaskInt) - 1) - (end_bit - 1)));
            }
        }
    }

    /// Removes a specific bit from the bit set
    pub fn unset(self: *Self, index: usize) void {
        assert(index < self.bit_length);
        self.masks[maskIndex(index)] &= ~maskBit(index);
    }

    /// Set all bits to 0.
    pub fn unsetAll(self: *Self) void {
        const masks_len = numMasks(self.bit_length);
        @memset(self.masks[0..masks_len], 0);
    }

    /// Set all bits to 1.
    pub fn setAll(self: *Self) void {
        const masks_len = numMasks(self.bit_length);
        @memset(self.masks[0..masks_len], std.math.maxInt(MaskInt));
    }

    /// Flips a specific bit in the bit set
    pub fn toggle(self: *Self, index: usize) void {
        assert(index < self.bit_length);
        self.masks[maskIndex(index)] ^= maskBit(index);
    }

    /// Flips all bits in this bit set which are present
    /// in the toggles bit set.  Both sets must have the
    /// same bit_length.
    pub fn toggleSet(self: *Self, toggles: Self) void {
        assert(toggles.bit_length == self.bit_length);
        const num_masks = numMasks(self.bit_length);
        for (self.masks[0..num_masks], 0..) |*mask, i| {
            mask.* ^= toggles.masks[i];
        }
    }

    /// Flips every bit in the bit set.
    pub fn toggleAll(self: *Self) void {
        const bit_length = self.bit_length;
        // avoid underflow if bit_length is zero
        if (bit_length == 0) return;

        const num_masks = numMasks(self.bit_length);
        for (self.masks[0..num_masks]) |*mask| {
            mask.* = ~mask.*;
        }

        const padding_bits = num_masks * @bitSizeOf(MaskInt) - bit_length;
        const last_item_mask = (~@as(MaskInt, 0)) >> @as(ShiftInt, @intCast(padding_bits));
        self.masks[num_masks - 1] &= last_item_mask;
    }

    /// Performs a union of two bit sets, and stores the
    /// result in the first one.  Bits in the result are
    /// set if the corresponding bits were set in either input.
    /// The two sets must both be the same bit_length.
    pub fn setUnion(self: *Self, other: Self) void {
        assert(other.bit_length == self.bit_length);
        const num_masks = numMasks(self.bit_length);
        for (self.masks[0..num_masks], 0..) |*mask, i| {
            mask.* |= other.masks[i];
        }
    }

    /// Performs an intersection of two bit sets, and stores
    /// the result in the first one.  Bits in the result are
    /// set if the corresponding bits were set in both inputs.
    /// The two sets must both be the same bit_length.
    pub fn setIntersection(self: *Self, other: Self) void {
        assert(other.bit_length == self.bit_length);
        const num_masks = numMasks(self.bit_length);
        for (self.masks[0..num_masks], 0..) |*mask, i| {
            mask.* &= other.masks[i];
        }
    }

    /// Finds the index of the first set bit.
    /// If no bits are set, returns null.
    pub fn findFirstSet(self: Self) ?usize {
        var offset: usize = 0;
        var mask = self.masks;
        while (offset < self.bit_length) {
            if (mask[0] != 0) break;
            mask += 1;
            offset += @bitSizeOf(MaskInt);
        } else return null;
        return offset + @ctz(mask[0]);
    }

    /// Finds the index of the last set bit.
    /// If no bits are set, returns null.
    pub fn findLastSet(self: Self) ?usize {
        if (self.bit_length == 0) return null;
        const bs = @bitSizeOf(MaskInt);
        var len = self.bit_length / bs;
        if (self.bit_length % bs != 0) len += 1;
        var offset: usize = len * bs;
        var idx: usize = len - 1;
        while (self.masks[idx] == 0) : (idx -= 1) {
            offset -= bs;
            if (idx == 0) return null;
        }
        offset -= @clz(self.masks[idx]);
        offset -= 1;
        return offset;
    }

    /// Finds the index of the first set bit, and unsets it.
    /// If no bits are set, returns null.
    pub fn toggleFirstSet(self: *Self) ?usize {
        var offset: usize = 0;
        var mask = self.masks;
        while (offset < self.bit_length) {
            if (mask[0] != 0) break;
            mask += 1;
            offset += @bitSizeOf(MaskInt);
        } else return null;
        const index = @ctz(mask[0]);
        mask[0] &= (mask[0] - 1);
        return offset + index;
    }

    /// Returns true iff every corresponding bit in both
    /// bit sets are the same.
    pub fn eql(self: Self, other: Self) bool {
        if (self.bit_length != other.bit_length) {
            return false;
        }
        const num_masks = numMasks(self.bit_length);
        var i: usize = 0;
        return while (i < num_masks) : (i += 1) {
            if (self.masks[i] != other.masks[i]) {
                break false;
            }
        } else true;
    }

    /// Returns true iff the first bit set is the subset
    /// of the second one.
    pub fn subsetOf(self: Self, other: Self) bool {
        if (self.bit_length != other.bit_length) {
            return false;
        }
        const num_masks = numMasks(self.bit_length);
        var i: usize = 0;
        return while (i < num_masks) : (i += 1) {
            if (self.masks[i] & other.masks[i] != self.masks[i]) {
                break false;
            }
        } else true;
    }

    /// Returns true iff the first bit set is the superset
    /// of the second one.
    pub fn supersetOf(self: Self, other: Self) bool {
        if (self.bit_length != other.bit_length) {
            return false;
        }
        const num_masks = numMasks(self.bit_length);
        var i: usize = 0;
        return while (i < num_masks) : (i += 1) {
            if (self.masks[i] & other.masks[i] != other.masks[i]) {
                break false;
            }
        } else true;
    }

    /// Iterates through the items in the set, according to the options.
    /// The default options (.{}) will iterate indices of set bits in
    /// ascending order.  Modifications to the underlying bit set may
    /// or may not be observed by the iterator.  Resizing the underlying
    /// bit set invalidates the iterator.
    pub fn iterator(self: *const Self, comptime options: IteratorOptions) Iterator(options) {
        const num_masks = numMasks(self.bit_length);
        const padding_bits = num_masks * @bitSizeOf(MaskInt) - self.bit_length;
        const last_item_mask = (~@as(MaskInt, 0)) >> @as(ShiftInt, @intCast(padding_bits));
        return Iterator(options).init(self.masks[0..num_masks], last_item_mask);
    }

    pub fn Iterator(comptime options: IteratorOptions) type {
        return BitSetIterator(MaskInt, options);
    }

    fn maskBit(index: usize) MaskInt {
        return @as(MaskInt, 1) << @as(ShiftInt, @truncate(index));
    }
    fn maskIndex(index: usize) usize {
        return index >> @bitSizeOf(ShiftInt);
    }
    fn boolMaskBit(index: usize, value: bool) MaskInt {
        return @as(MaskInt, @intFromBool(value)) << @as(ShiftInt, @intCast(index));
    }
    fn numMasks(bit_length: usize) usize {
        return (bit_length + (@bitSizeOf(MaskInt) - 1)) / @bitSizeOf(MaskInt);
    }
};

/// A bit set with runtime-known size, backed by an allocated slice
/// of usize.  Thin wrapper around DynamicBitSetUnmanaged which keeps
/// track of the allocator instance.
pub const DynamicBitSet = struct {
    const Self = @This();

    /// The integer type used to represent a mask in this bit set
    pub const MaskInt = usize;

    /// The integer type used to shift a mask in this bit set
    pub const ShiftInt = std.math.Log2Int(MaskInt);

    allocator: Allocator,
    unmanaged: DynamicBitSetUnmanaged = .{},

    /// Creates a bit set with no elements present.
    pub fn initEmpty(allocator: Allocator, bit_length: usize) !Self {
        return Self{
            .unmanaged = try DynamicBitSetUnmanaged.initEmpty(allocator, bit_length),
            .allocator = allocator,
        };
    }

    /// Creates a bit set with all elements present.
    pub fn initFull(allocator: Allocator, bit_length: usize) !Self {
        return Self{
            .unmanaged = try DynamicBitSetUnmanaged.initFull(allocator, bit_length),
            .allocator = allocator,
        };
    }

    /// Resizes to a new length.  If the new length is larger
    /// than the old length, fills any added bits with `fill`.
    pub fn resize(self: *@This(), new_len: usize, fill: bool) !void {
        try self.unmanaged.resize(self.allocator, new_len, fill);
    }

    /// Deinitializes the array and releases its memory.
    /// The passed allocator must be the same one used for
    /// init* or resize in the past.
    pub fn deinit(self: *Self) void {
        self.unmanaged.deinit(self.allocator);
    }

    /// Creates a duplicate of this bit set, using the new allocator.
    pub fn clone(self: *const Self, new_allocator: Allocator) !Self {
        return Self{
            .unmanaged = try self.unmanaged.clone(new_allocator),
            .allocator = new_allocator,
        };
    }

    /// Returns the number of bits in this bit set
    pub inline fn capacity(self: Self) usize {
        return self.unmanaged.capacity();
    }

    /// Returns true if the bit at the specified index
    /// is present in the set, false otherwise.
    pub fn isSet(self: Self, index: usize) bool {
        return self.unmanaged.isSet(index);
    }

    /// Returns the total number of set bits in this bit set.
    pub fn count(self: Self) usize {
        return self.unmanaged.count();
    }

    /// Changes the value of the specified bit of the bit
    /// set to match the passed boolean.
    pub fn setValue(self: *Self, index: usize, value: bool) void {
        self.unmanaged.setValue(index, value);
    }

    /// Adds a specific bit to the bit set
    pub fn set(self: *Self, index: usize) void {
        self.unmanaged.set(index);
    }

    /// Changes the value of all bits in the specified range to
    /// match the passed boolean.
    pub fn setRangeValue(self: *Self, range: Range, value: bool) void {
        self.unmanaged.setRangeValue(range, value);
    }

    /// Removes a specific bit from the bit set
    pub fn unset(self: *Self, index: usize) void {
        self.unmanaged.unset(index);
    }

    /// Flips a specific bit in the bit set
    pub fn toggle(self: *Self, index: usize) void {
        self.unmanaged.toggle(index);
    }

    /// Flips all bits in this bit set which are present
    /// in the toggles bit set.  Both sets must have the
    /// same bit_length.
    pub fn toggleSet(self: *Self, toggles: Self) void {
        self.unmanaged.toggleSet(toggles.unmanaged);
    }

    /// Flips every bit in the bit set.
    pub fn toggleAll(self: *Self) void {
        self.unmanaged.toggleAll();
    }

    /// Performs a union of two bit sets, and stores the
    /// result in the first one.  Bits in the result are
    /// set if the corresponding bits were set in either input.
    /// The two sets must both be the same bit_length.
    pub fn setUnion(self: *Self, other: Self) void {
        self.unmanaged.setUnion(other.unmanaged);
    }

    /// Performs an intersection of two bit sets, and stores
    /// the result in the first one.  Bits in the result are
    /// set if the corresponding bits were set in both inputs.
    /// The two sets must both be the same bit_length.
    pub fn setIntersection(self: *Self, other: Self) void {
        self.unmanaged.setIntersection(other.unmanaged);
    }

    /// Finds the index of the first set bit.
    /// If no bits are set, returns null.
    pub fn findFirstSet(self: Self) ?usize {
        return self.unmanaged.findFirstSet();
    }

    /// Finds the index of the last set bit.
    /// If no bits are set, returns null.
    pub fn findLastSet(self: Self) ?usize {
        return self.unmanaged.findLastSet();
    }

    /// Finds the index of the first set bit, and unsets it.
    /// If no bits are set, returns null.
    pub fn toggleFirstSet(self: *Self) ?usize {
        return self.unmanaged.toggleFirstSet();
    }

    /// Returns true iff every corresponding bit in both
    /// bit sets are the same.
    pub fn eql(self: Self, other: Self) bool {
        return self.unmanaged.eql(other.unmanaged);
    }

    /// Iterates through the items in the set, according to the options.
    /// The default options (.{}) will iterate indices of set bits in
    /// ascending order.  Modifications to the underlying bit set may
    /// or may not be observed by the iterator.  Resizing the underlying
    /// bit set invalidates the iterator.
    pub fn iterator(self: *const Self, comptime options: IteratorOptions) Iterator(options) {
        return self.unmanaged.iterator(options);
    }

    pub const Iterator = DynamicBitSetUnmanaged.Iterator;
};

/// Options for configuring an iterator over a bit set
pub const IteratorOptions = struct {
    /// determines which bits should be visited
    kind: Type = .set,
    /// determines the order in which bit indices should be visited
    direction: Direction = .forward,

    pub const Type = enum {
        /// visit indexes of set bits
        set,
        /// visit indexes of unset bits
        unset,
    };

    pub const Direction = enum {
        /// visit indices in ascending order
        forward,
        /// visit indices in descending order.
        /// Note that this may be slightly more expensive than forward iteration.
        reverse,
    };
};

// The iterator is reusable between several bit set types
fn BitSetIterator(comptime MaskInt: type, comptime options: IteratorOptions) type {
    const ShiftInt = std.math.Log2Int(MaskInt);
    const kind = options.kind;
    const direction = options.direction;
    return struct {
        const Self = @This();

        // all bits which have not yet been iterated over
        bits_remain: MaskInt,
        // all words which have not yet been iterated over
        words_remain: []const MaskInt,
        // the offset of the current word
        bit_offset: usize,
        // the mask of the last word
        last_word_mask: MaskInt,

        fn init(masks: []const MaskInt, last_word_mask: MaskInt) Self {
            if (masks.len == 0) {
                return Self{
                    .bits_remain = 0,
                    .words_remain = &[_]MaskInt{},
                    .last_word_mask = last_word_mask,
                    .bit_offset = 0,
                };
            } else {
                var result = Self{
                    .bits_remain = 0,
                    .words_remain = masks,
                    .last_word_mask = last_word_mask,
                    .bit_offset = if (direction == .forward) 0 else (masks.len - 1) * @bitSizeOf(MaskInt),
                };
                result.nextWord(true);
                return result;
            }
        }

        /// Returns the index of the next unvisited set bit
        /// in the bit set, in ascending order.
        pub fn next(self: *Self) ?usize {
            while (self.bits_remain == 0) {
                if (self.words_remain.len == 0) return null;
                self.nextWord(false);
                switch (direction) {
                    .forward => self.bit_offset += @bitSizeOf(MaskInt),
                    .reverse => self.bit_offset -= @bitSizeOf(MaskInt),
                }
            }

            switch (direction) {
                .forward => {
                    const next_index = @ctz(self.bits_remain) + self.bit_offset;
                    self.bits_remain &= self.bits_remain - 1;
                    return next_index;
                },
                .reverse => {
                    const leading_zeroes = @clz(self.bits_remain);
                    const top_bit = (@bitSizeOf(MaskInt) - 1) - leading_zeroes;
                    const no_top_bit_mask = (@as(MaskInt, 1) << @as(ShiftInt, @intCast(top_bit))) - 1;
                    self.bits_remain &= no_top_bit_mask;
                    return top_bit + self.bit_offset;
                },
            }
        }

        // Load the next word.  Don't call this if there
        // isn't a next word.  If the next word is the
        // last word, mask off the padding bits so we
        // don't visit them.
        inline fn nextWord(self: *Self, comptime is_first_word: bool) void {
            var word = switch (direction) {
                .forward => self.words_remain[0],
                .reverse => self.words_remain[self.words_remain.len - 1],
            };
            switch (kind) {
                .set => {},
                .unset => {
                    word = ~word;
                    if ((direction == .reverse and is_first_word) or
                        (direction == .forward and self.words_remain.len == 1))
                    {
                        word &= self.last_word_mask;
                    }
                },
            }
            switch (direction) {
                .forward => self.words_remain = self.words_remain[1..],
                .reverse => self.words_remain.len -= 1,
            }
            self.bits_remain = word;
        }
    };
}

/// A range of indices within a bitset.
pub const Range = struct {
    /// The index of the first bit of interest.
    start: usize,
    /// The index immediately after the last bit of interest.
    end: usize,
};

// ---------------- Tests -----------------

const testing = std.testing;

fn testEql(empty: anytype, full: anytype, len: usize) !void {
    try testing.expect(empty.eql(empty));
    try testing.expect(full.eql(full));
    switch (len) {
        0 => {
            try testing.expect(empty.eql(full));
            try testing.expect(full.eql(empty));
        },
        else => {
            try testing.expect(!empty.eql(full));
            try testing.expect(!full.eql(empty));
        },
    }
}

fn testSubsetOf(empty: anytype, full: anytype, even: anytype, odd: anytype, len: usize) !void {
    try testing.expect(empty.subsetOf(empty));
    try testing.expect(empty.subsetOf(full));
    try testing.expect(full.subsetOf(full));
    switch (len) {
        0 => {
            try testing.expect(even.subsetOf(odd));
            try testing.expect(odd.subsetOf(even));
        },
        1 => {
            try testing.expect(!even.subsetOf(odd));
            try testing.expect(odd.subsetOf(even));
        },
        else => {
            try testing.expect(!even.subsetOf(odd));
            try testing.expect(!odd.subsetOf(even));
        },
    }
}

fn testSupersetOf(empty: anytype, full: anytype, even: anytype, odd: anytype, len: usize) !void {
    try testing.expect(full.supersetOf(full));
    try testing.expect(full.supersetOf(empty));
    try testing.expect(empty.supersetOf(empty));
    switch (len) {
        0 => {
            try testing.expect(even.supersetOf(odd));
            try testing.expect(odd.supersetOf(even));
        },
        1 => {
            try testing.expect(even.supersetOf(odd));
            try testing.expect(!odd.supersetOf(even));
        },
        else => {
            try testing.expect(!even.supersetOf(odd));
            try testing.expect(!odd.supersetOf(even));
        },
    }
}

fn testBitSet(a: anytype, b: anytype, len: usize) !void {
    try testing.expectEqual(len, a.capacity());
    try testing.expectEqual(len, b.capacity());

    {
        var i: usize = 0;
        while (i < len) : (i += 1) {
            a.setValue(i, i & 1 == 0);
            b.setValue(i, i & 2 == 0);
        }
    }

    try testing.expectEqual((len + 1) / 2, a.count());
    try testing.expectEqual((len + 3) / 4 + (len + 2) / 4, b.count());

    {
        var iter = a.iterator(.{});
        var i: usize = 0;
        while (i < len) : (i += 2) {
            try testing.expectEqual(@as(?usize, i), iter.next());
        }
        try testing.expectEqual(@as(?usize, null), iter.next());
        try testing.expectEqual(@as(?usize, null), iter.next());
        try testing.expectEqual(@as(?usize, null), iter.next());
    }
    a.toggleAll();
    {
        var iter = a.iterator(.{});
        var i: usize = 1;
        while (i < len) : (i += 2) {
            try testing.expectEqual(@as(?usize, i), iter.next());
        }
        try testing.expectEqual(@as(?usize, null), iter.next());
        try testing.expectEqual(@as(?usize, null), iter.next());
        try testing.expectEqual(@as(?usize, null), iter.next());
    }

    {
        var iter = b.iterator(.{ .kind = .unset });
        var i: usize = 2;
        while (i < len) : (i += 4) {
            try testing.expectEqual(@as(?usize, i), iter.next());
            if (i + 1 < len) {
                try testing.expectEqual(@as(?usize, i + 1), iter.next());
            }
        }
        try testing.expectEqual(@as(?usize, null), iter.next());
        try testing.expectEqual(@as(?usize, null), iter.next());
        try testing.expectEqual(@as(?usize, null), iter.next());
    }

    {
        var i: usize = 0;
        while (i < len) : (i += 1) {
            try testing.expectEqual(i & 1 != 0, a.isSet(i));
            try testing.expectEqual(i & 2 == 0, b.isSet(i));
        }
    }

    a.setUnion(b.*);
    {
        var i: usize = 0;
        while (i < len) : (i += 1) {
            try testing.expectEqual(i & 1 != 0 or i & 2 == 0, a.isSet(i));
            try testing.expectEqual(i & 2 == 0, b.isSet(i));
        }

        i = len;
        var set = a.iterator(.{ .direction = .reverse });
        var unset = a.iterator(.{ .kind = .unset, .direction = .reverse });
        while (i > 0) {
            i -= 1;
            if (i & 1 != 0 or i & 2 == 0) {
                try testing.expectEqual(@as(?usize, i), set.next());
            } else {
                try testing.expectEqual(@as(?usize, i), unset.next());
            }
        }
        try testing.expectEqual(@as(?usize, null), set.next());
        try testing.expectEqual(@as(?usize, null), set.next());
        try testing.expectEqual(@as(?usize, null), set.next());
        try testing.expectEqual(@as(?usize, null), unset.next());
        try testing.expectEqual(@as(?usize, null), unset.next());
        try testing.expectEqual(@as(?usize, null), unset.next());
    }

    a.toggleSet(b.*);
    {
        try testing.expectEqual(len / 4, a.count());

        var i: usize = 0;
        while (i < len) : (i += 1) {
            try testing.expectEqual(i & 1 != 0 and i & 2 != 0, a.isSet(i));
            try testing.expectEqual(i & 2 == 0, b.isSet(i));
            if (i & 1 == 0) {
                a.set(i);
            } else {
                a.unset(i);
            }
        }
    }

    a.setIntersection(b.*);
    {
        try testing.expectEqual((len + 3) / 4, a.count());

        var i: usize = 0;
        while (i < len) : (i += 1) {
            try testing.expectEqual(i & 1 == 0 and i & 2 == 0, a.isSet(i));
            try testing.expectEqual(i & 2 == 0, b.isSet(i));
        }
    }

    a.toggleSet(a.*);
    {
        var iter = a.iterator(.{});
        try testing.expectEqual(@as(?usize, null), iter.next());
        try testing.expectEqual(@as(?usize, null), iter.next());
        try testing.expectEqual(@as(?usize, null), iter.next());
        try testing.expectEqual(@as(usize, 0), a.count());
    }
    {
        var iter = a.iterator(.{ .direction = .reverse });
        try testing.expectEqual(@as(?usize, null), iter.next());
        try testing.expectEqual(@as(?usize, null), iter.next());
        try testing.expectEqual(@as(?usize, null), iter.next());
        try testing.expectEqual(@as(usize, 0), a.count());
    }

    const test_bits = [_]usize{
        0,  1,  2,   3,   4,   5,    6, 7, 9, 10, 11, 22, 31, 32, 63, 64,
        66, 95, 127, 160, 192, 1000,
    };
    for (test_bits) |i| {
        if (i < a.capacity()) {
            a.set(i);
        }
    }

    for (test_bits) |i| {
        if (i < a.capacity()) {
            try testing.expectEqual(@as(?usize, i), a.findFirstSet());
            try testing.expectEqual(@as(?usize, i), a.toggleFirstSet());
        }
    }
    try testing.expectEqual(@as(?usize, null), a.findFirstSet());
    try testing.expectEqual(@as(?usize, null), a.findLastSet());
    try testing.expectEqual(@as(?usize, null), a.toggleFirstSet());
    try testing.expectEqual(@as(?usize, null), a.findFirstSet());
    try testing.expectEqual(@as(?usize, null), a.findLastSet());
    try testing.expectEqual(@as(?usize, null), a.toggleFirstSet());
    try testing.expectEqual(@as(usize, 0), a.count());

    a.setRangeValue(.{ .start = 0, .end = len }, false);
    try testing.expectEqual(@as(usize, 0), a.count());

    a.setRangeValue(.{ .start = 0, .end = len }, true);
    try testing.expectEqual(len, a.count());

    a.setRangeValue(.{ .start = 0, .end = len }, false);
    a.setRangeValue(.{ .start = 0, .end = 0 }, true);
    try testing.expectEqual(@as(usize, 0), a.count());

    a.setRangeValue(.{ .start = len, .end = len }, true);
    try testing.expectEqual(@as(usize, 0), a.count());

    if (len >= 1) {
        a.setRangeValue(.{ .start = 0, .end = len }, false);
        a.setRangeValue(.{ .start = 0, .end = 1 }, true);
        try testing.expectEqual(@as(usize, 1), a.count());
        try testing.expect(a.isSet(0));

        a.setRangeValue(.{ .start = 0, .end = len }, false);
        a.setRangeValue(.{ .start = 0, .end = len - 1 }, true);
        try testing.expectEqual(len - 1, a.count());
        try testing.expect(!a.isSet(len - 1));

        a.setRangeValue(.{ .start = 0, .end = len }, false);
        a.setRangeValue(.{ .start = 1, .end = len }, true);
        try testing.expectEqual(@as(usize, len - 1), a.count());
        try testing.expect(!a.isSet(0));

        a.setRangeValue(.{ .start = 0, .end = len }, false);
        a.setRangeValue(.{ .start = len - 1, .end = len }, true);
        try testing.expectEqual(@as(usize, 1), a.count());
        try testing.expect(a.isSet(len - 1));

        if (len >= 4) {
            a.setRangeValue(.{ .start = 0, .end = len }, false);
            a.setRangeValue(.{ .start = 1, .end = len - 2 }, true);
            try testing.expectEqual(@as(usize, len - 3), a.count());
            try testing.expect(!a.isSet(0));
            try testing.expect(a.isSet(1));
            try testing.expect(a.isSet(len - 3));
            try testing.expect(!a.isSet(len - 2));
            try testing.expect(!a.isSet(len - 1));
        }
    }
}

fn fillEven(set: anytype, len: usize) void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        set.setValue(i, i & 1 == 0);
    }
}

fn fillOdd(set: anytype, len: usize) void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        set.setValue(i, i & 1 == 1);
    }
}

fn testPureBitSet(comptime Set: type) !void {
    const empty = Set.initEmpty();
    const full = Set.initFull();

    const even = even: {
        var bit_set = Set.initEmpty();
        fillEven(&bit_set, Set.bit_length);
        break :even bit_set;
    };

    const odd = odd: {
        var bit_set = Set.initEmpty();
        fillOdd(&bit_set, Set.bit_length);
        break :odd bit_set;
    };

    try testSubsetOf(empty, full, even, odd, Set.bit_length);
    try testSupersetOf(empty, full, even, odd, Set.bit_length);

    try testing.expect(empty.complement().eql(full));
    try testing.expect(full.complement().eql(empty));
    try testing.expect(even.complement().eql(odd));
    try testing.expect(odd.complement().eql(even));

    try testing.expect(empty.unionWith(empty).eql(empty));
    try testing.expect(empty.unionWith(full).eql(full));
    try testing.expect(full.unionWith(full).eql(full));
    try testing.expect(full.unionWith(empty).eql(full));
    try testing.expect(even.unionWith(odd).eql(full));
    try testing.expect(odd.unionWith(even).eql(full));

    try testing.expect(empty.intersectWith(empty).eql(empty));
    try testing.expect(empty.intersectWith(full).eql(empty));
    try testing.expect(full.intersectWith(full).eql(full));
    try testing.expect(full.intersectWith(empty).eql(empty));
    try testing.expect(even.intersectWith(odd).eql(empty));
    try testing.expect(odd.intersectWith(even).eql(empty));

    try testing.expect(empty.xorWith(empty).eql(empty));
    try testing.expect(empty.xorWith(full).eql(full));
    try testing.expect(full.xorWith(full).eql(empty));
    try testing.expect(full.xorWith(empty).eql(full));
    try testing.expect(even.xorWith(odd).eql(full));
    try testing.expect(odd.xorWith(even).eql(full));

    try testing.expect(empty.differenceWith(empty).eql(empty));
    try testing.expect(empty.differenceWith(full).eql(empty));
    try testing.expect(full.differenceWith(full).eql(empty));
    try testing.expect(full.differenceWith(empty).eql(full));
    try testing.expect(full.differenceWith(odd).eql(even));
    try testing.expect(full.differenceWith(even).eql(odd));
}

fn testStaticBitSet(comptime Set: type) !void {
    var a = Set.initEmpty();
    var b = Set.initFull();
    try testing.expectEqual(@as(usize, 0), a.count());
    try testing.expectEqual(@as(usize, Set.bit_length), b.count());

    try testEql(a, b, Set.bit_length);
    try testBitSet(&a, &b, Set.bit_length);

    try testPureBitSet(Set);
}

test IntegerBitSet {
    if (builtin.zig_backend == .stage2_c) return error.SkipZigTest;
    if (comptime builtin.cpu.has(.riscv, .v) and builtin.zig_backend == .stage2_llvm) return error.SkipZigTest; // https://github.com/ziglang/zig/issues/24300

    try testStaticBitSet(IntegerBitSet(0));
    try testStaticBitSet(IntegerBitSet(1));
    try testStaticBitSet(IntegerBitSet(2));
    try testStaticBitSet(IntegerBitSet(5));
    try testStaticBitSet(IntegerBitSet(8));
    try testStaticBitSet(IntegerBitSet(32));
    try testStaticBitSet(IntegerBitSet(64));
    try testStaticBitSet(IntegerBitSet(127));
}

test ArrayBitSet {
    inline for (.{ 0, 1, 2, 31, 32, 33, 63, 64, 65, 254, 500, 3000 }) |size| {
        try testStaticBitSet(ArrayBitSet(u8, size));
        try testStaticBitSet(ArrayBitSet(u16, size));
        try testStaticBitSet(ArrayBitSet(u32, size));
        try testStaticBitSet(ArrayBitSet(u64, size));
        try testStaticBitSet(ArrayBitSet(u128, size));
    }
}

test DynamicBitSetUnmanaged {
    const allocator = std.testing.allocator;
    var a = try DynamicBitSetUnmanaged.initEmpty(allocator, 300);
    try testing.expectEqual(@as(usize, 0), a.count());
    a.deinit(allocator);

    a = try DynamicBitSetUnmanaged.initEmpty(allocator, 0);
    defer a.deinit(allocator);
    for ([_]usize{ 1, 2, 31, 32, 33, 0, 65, 64, 63, 500, 254, 3000 }) |size| {
        const old_len = a.capacity();

        var empty = try a.clone(allocator);
        defer empty.deinit(allocator);
        try testing.expectEqual(old_len, empty.capacity());
        var i: usize = 0;
        while (i < old_len) : (i += 1) {
            try testing.expectEqual(a.isSet(i), empty.isSet(i));
        }

        a.toggleSet(a); // zero a
        empty.toggleSet(empty);

        try a.resize(allocator, size, true);
        try empty.resize(allocator, size, false);

        if (size > old_len) {
            try testing.expectEqual(size - old_len, a.count());
        } else {
            try testing.expectEqual(@as(usize, 0), a.count());
        }
        try testing.expectEqual(@as(usize, 0), empty.count());

        var full = try DynamicBitSetUnmanaged.initFull(allocator, size);
        defer full.deinit(allocator);
        try testing.expectEqual(@as(usize, size), full.count());

        try testEql(empty, full, size);
        {
            var even = try DynamicBitSetUnmanaged.initEmpty(allocator, size);
            defer even.deinit(allocator);
            fillEven(&even, size);

            var odd = try DynamicBitSetUnmanaged.initEmpty(allocator, size);
            defer odd.deinit(allocator);
            fillOdd(&odd, size);

            try testSubsetOf(empty, full, even, odd, size);
            try testSupersetOf(empty, full, even, odd, size);
        }
        try testBitSet(&a, &full, size);
    }
}

test DynamicBitSet {
    const allocator = std.testing.allocator;
    var a = try DynamicBitSet.initEmpty(allocator, 300);
    try testing.expectEqual(@as(usize, 0), a.count());
    a.deinit();

    a = try DynamicBitSet.initEmpty(allocator, 0);
    defer a.deinit();
    for ([_]usize{ 1, 2, 31, 32, 33, 0, 65, 64, 63, 500, 254, 3000 }) |size| {
        const old_len = a.capacity();

        var tmp = try a.clone(allocator);
        defer tmp.deinit();
        try testing.expectEqual(old_len, tmp.capacity());
        var i: usize = 0;
        while (i < old_len) : (i += 1) {
            try testing.expectEqual(a.isSet(i), tmp.isSet(i));
        }

        a.toggleSet(a); // zero a
        tmp.toggleSet(tmp); // zero tmp

        try a.resize(size, true);
        try tmp.resize(size, false);

        if (size > old_len) {
            try testing.expectEqual(size - old_len, a.count());
        } else {
            try testing.expectEqual(@as(usize, 0), a.count());
        }
        try testing.expectEqual(@as(usize, 0), tmp.count());

        var b = try DynamicBitSet.initFull(allocator, size);
        defer b.deinit();
        try testing.expectEqual(@as(usize, size), b.count());

        try testEql(tmp, b, size);
        try testBitSet(&a, &b, size);
    }
}

test StaticBitSet {
    try testing.expectEqual(IntegerBitSet(0), StaticBitSet(0));
    try testing.expectEqual(IntegerBitSet(5), StaticBitSet(5));
    try testing.expectEqual(IntegerBitSet(@bitSizeOf(usize)), StaticBitSet(@bitSizeOf(usize)));
    try testing.expectEqual(ArrayBitSet(usize, @bitSizeOf(usize) + 1), StaticBitSet(@bitSizeOf(usize) + 1));
    try testing.expectEqual(ArrayBitSet(usize, 500), StaticBitSet(500));
}
