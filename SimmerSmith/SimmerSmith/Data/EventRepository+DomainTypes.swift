#if canImport(CloudKit)
import SimmerSmithKit

// Domain-type aliases for EventRepository.
//
// EventRepository.swift must `import GroceryMerge` (it names many merge value types), which makes
// bare `Event` ambiguous in that file. The domain `Event` can't be disambiguated by
// module-qualification because the module name `SimmerSmithKit` is shadowed by an enum of the same
// name. This file does NOT import GroceryMerge, so `Event` here resolves unambiguously to the
// SimmerSmithKit domain aggregate — the alias lets EventRepository name the domain type.

typealias DomainEvent = Event
#endif
