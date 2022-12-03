import Combine
import StoreKit
import SwiftUI

public class StoreKitted: ObservableObject {
    public typealias Product = StoreKit.Product
    public typealias Transaction = StoreKit.Transaction
    public typealias TransactionVerificationResult = VerificationResult<Transaction>

    public enum PurchaseError: Error {
        case canceled
        case errorFailure(Error)
        case fail
        case pending
        case successWithConversionError
        case verification
        case unknown

        var userInfo: [String: String] {
            switch self {
            case .canceled:
                return [:]
            case .errorFailure(let error):
                return [NSLocalizedDescriptionKey: "\(error.localizedDescription)"]
            case .fail, .unknown:
                return [NSLocalizedDescriptionKey: "An unknown error occurred. Please try again later"]
            case .pending:
                return [NSLocalizedDescriptionKey: "Your purchase is pending. Once it's completed, your purchase will be activated"]
            case .successWithConversionError:
                return [NSLocalizedDescriptionKey: "Your purchase appears to have completed successfully but we're unable to verify it at this time. Once verification succeeds, your purchase will be activated. Thank you for your patience"]
            case .verification:
                return [NSLocalizedDescriptionKey: "Your purchase failed verification. Please try again"]
            }
        }
    }

    @Published var fetchedProducts: [Product] = []
    @Published var purchasedProducts: [Product] = []
    @Published private var purchaseManager: PurchaseManager
    private var cancellable: AnyCancellable?

    public init(productIds: [String]) {
        self.purchaseManager = .init(productIds: productIds)
        cancellable = purchaseManager.objectWillChange.sink { [weak self] in
            guard let self = self else { return }
            self.fetchedProducts = self.purchaseManager.fetchedProducts
            self.purchasedProducts = self.purchaseManager.purchasedProducts
        }
    }

    public func addProductId(_ productId: String) async {
        PurchaseManager.productIds.append(productId)
        _ = try? await purchaseManager.fetchProducts()
    }
    @MainActor
    @discardableResult public func fetchProducts() async throws -> [Product] {
        try await purchaseManager.fetchProducts()
    }
    @MainActor
    public func requestAndHandlePurchase(_ product: Product) async -> Result<Product, PurchaseError> {
        await purchaseManager.requestAndHandlePurchase(product)
    }
    @MainActor
    public func restorePurchases() async throws  {
        try await purchaseManager.fetchProducts()
    }
}

class PurchaseManager: NSObject, ObservableObject, SKPaymentTransactionObserver {
    private typealias Transaction = StoreKit.Transaction
    private typealias TransactionVerificationResult = VerificationResult<Transaction>

    // MARK: Init
    static var productIds: [String] = []
    private var updateListenerTask: Task<Void, Error>? = nil
    init(productIds: [String]) {
        super.init()
        Self.productIds = productIds
        updateListenerTask = listenForTransactions()
        Task {
            try? await fetchProducts()
        }
    }

    @Published var fetchedProducts: [Product] = []
    @Published var purchasedProducts: [Product] = []

    @MainActor
    @discardableResult func fetchProducts(processPurchasesHandler: @escaping ([Product]) async -> Void = { _ in }) async throws -> [Product] {
        let products = try await Product.products(for: Self.productIds)
        guard products.first != nil else { throw StoreKitted.PurchaseError.unknown }
        self.fetchedProducts = products
        try await checkPurchased()
        return products
    }

    @MainActor
    private func checkPurchased() async throws {
        for product in fetchedProducts {
            guard let state = await product.currentEntitlement else { continue }
            let transaction = try self.checkVerified(state)
            //Always finish a transaction.
            await transaction.finish()
        }
    }

    /// Call when the user initiates a purchase in order to handle actions (such as cancel) and errors (such as `.fail`)
    @MainActor
    @discardableResult func requestAndHandlePurchase(_ product: Product) async -> Result<Product, StoreKitted.PurchaseError> {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let transactionResult):
                switch transactionResult {
                case let .verified(transaction):
                    guard let product = map(productId: transaction.productID) else {
                        return .failure(.successWithConversionError)
                    }
                    self.purchasedProducts.append(product)
                    return .success(product)
                case .unverified:
                    return .failure(.fail)
                }
            case .userCancelled:
                return .failure(.canceled)
            case .pending:
                return .failure(.pending)
            @unknown default:
                return .failure(.unknown)
            }
        } catch {
            return .failure(.errorFailure(error))
        }
    }

    func restorePurchases() async throws  {
        try await fetchProducts() { [weak self] products in
            try? await self?.checkPurchased()
        }
    }
    // MARK: Helpers
    private func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            //Iterate through any transactions that don't come from a direct call to `purchase()`.
            for await result in Transaction.updates {
                do {
                    let transaction = try self.checkVerified(result)

                    //Always finish a transaction.
                    await transaction.finish()
                } catch {
                    //StoreKit has a transaction that fails verification. Don't deliver content to the user.
                    throw error
                }
            }
        }
    }

    private func checkVerified(_ result: TransactionVerificationResult) throws -> Transaction {
        switch result {
        case .verified(let transaction):
            guard let product = map(productId: transaction.productID) else {
                return transaction
            }
            self.purchasedProducts.append(product)
        case .unverified:
            throw StoreKitted.PurchaseError.verification
        }
        throw StoreKitted.PurchaseError.unknown
    }

    private func map(productId: String) -> Product? {
        fetchedProducts.first { $0.id == productId }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    // MARK: SKPaymentQueue Listener
    func paymentQueue(
        _ queue: SKPaymentQueue,
        shouldAddStorePayment payment: SKPayment,
        for product: SKProduct
    ) -> Bool {
        fetchedProducts.map{ $0.id }.contains(product.productIdentifier)
    }

    func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        Task {
            try await fetchProducts()
        }
    }

}
