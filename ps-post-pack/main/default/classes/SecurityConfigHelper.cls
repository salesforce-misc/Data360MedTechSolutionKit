/**
 * Helper class for security and commerce configuration
 * - Retrieves domain information for CORS and CSP configuration
 * - Enables guest browsing and checkout for Commerce stores
 */
public with sharing class SecurityConfigHelper {

    /**
     * Retrieves all domain URLs needed for CORS and CSP configuration
     * Returns a Map with domain information that can be used to create metadata files
     */
    public static Map<String, String> getDomainUrls() {
        Map<String, String> domainInfo = new Map<String, String>();

        try {
            // Query Domain object to get all DNS domains
            List<Domain> allDomains = [SELECT Domain FROM Domain WHERE DomainType = 'DNS'];

            for (Domain d : allDomains) {
                if (d.Domain.contains('.my.site.com')) {
                    // Experience Cloud Sites Domain
                    domainInfo.put('experienceCloudDomain', d.Domain);
                    domainInfo.put('experienceCloudUrl', 'https://' + d.Domain);
                } else if (d.Domain.contains('.my.salesforce-sites.com')) {
                    // Salesforce Sites Domain (My Domain)
                    domainInfo.put('myDomain', d.Domain);
                    domainInfo.put('myDomainUrl', 'https://' + d.Domain);
                }
            }

            // Static Salesforce SCRT domain
            domainInfo.put('salesforceScrtUrl', 'https://*.my.salesforce-scrt.com');

            return domainInfo;

        } catch (Exception e) {
            System.debug('❌ Error retrieving domain URLs: ' + e.getMessage());
            throw e;
        }
    }

    /**
     * Prints domain URLs in a formatted way for easy metadata file creation
     * This method is called from scripts/apex/getDomainUrls.apex
     */
    public static void printDomainUrls() {
        try {
            Map<String, String> domains = getDomainUrls();

            System.debug('========================================');
            System.debug('🔐 CORS and CSP Domain Configuration');
            System.debug('========================================');
            System.debug('');
            System.debug('📋 CORS URLs (Create 3 CorsWhitelistOrigin metadata files):');
            System.debug('');
            System.debug('1. Salesforce SCRT:');
            System.debug('   URL: ' + domains.get('salesforceScrtUrl'));
            System.debug('');
            System.debug('2. My Domain:');
            System.debug('   URL: ' + domains.get('myDomainUrl'));
            System.debug('');
            System.debug('3. Experience Cloud Domain:');
            System.debug('   URL: ' + domains.get('experienceCloudUrl'));
            System.debug('');
            System.debug('========================================');
            System.debug('🛡️ CSP Trusted Site Configuration:');
            System.debug('========================================');
            System.debug('');
            System.debug('Name: PulseSync');
            System.debug('Endpoint URL: ' + domains.get('experienceCloudUrl'));
            System.debug('Enable all CSP directives:');
            System.debug('  - connect-src: true');
            System.debug('  - font-src: true');
            System.debug('  - frame-src: true');
            System.debug('  - img-src: true');
            System.debug('  - media-src: true');
            System.debug('  - style-src: true');
            System.debug('');
            System.debug('========================================');
            System.debug('✅ Domain URLs Retrieved Successfully');
            System.debug('========================================');

        } catch (Exception e) {
            System.debug('❌ ERROR: ' + e.getMessage());
            System.debug('Stack Trace: ' + e.getStackTraceString());
        }
    }

    /**
     * Enable guest browsing, guest checkout, guest cart access, and preserve-cart-on-login
     * for a Commerce store. The three LWR-specific toggles ("Cart access", "Preserve guest carts",
     * "Checkout access") map to WebStore boolean fields whose API names have shifted across
     * releases — so we set them via dynamic SObject puts using Schema introspection. That way
     * older orgs without one of the fields still succeed for the others.
     *
     * @param storeName Name of the WebStore to enable guest access for
     * @return Map with status and messages plus per-toggle final state
     */
    public static Map<String, String> enableGuestBrowsing(String storeName) {
        Map<String, String> result = new Map<String, String>();

        // Candidate field API names per UI toggle. First match on the WebStore SObject wins.
        // Cart access (LWR)
        List<String> cartAccessFieldCandidates = new List<String>{
            'OptionsGuestCartEnabled',
            'OptionsAllowGuestAddToCartEnabled',
            'OptionsAddToCartGuestEnabled'
        };
        // Preserve guest carts (LWR)
        List<String> preserveCartFieldCandidates = new List<String>{
            'OptionsPreserveGuestCartEnabled',
            'OptionsPreserveCartEnabled',
            'OptionsPreserveCartGuestUserEnabled',
            'OptionsKeepGuestCartEnabled'
        };

        try {
            Map<String, Schema.SObjectField> webStoreFields = Schema.SObjectType.WebStore.fields.getMap();
            String cartAccessField = pickFirstExistingField(webStoreFields, cartAccessFieldCandidates);
            String preserveCartField = pickFirstExistingField(webStoreFields, preserveCartFieldCandidates);

            // Build dynamic SOQL field list
            List<String> selectFields = new List<String>{
                'Id', 'Name', 'OptionsGuestBrowsingEnabled', 'OptionsGuestCheckoutEnabled'
            };
            if (cartAccessField != null) selectFields.add(cartAccessField);
            if (preserveCartField != null) selectFields.add(preserveCartField);

            String soql = 'SELECT ' + String.join(selectFields, ', ') +
                          ' FROM WebStore WHERE Name = :storeName LIMIT 1';
            List<WebStore> stores = Database.query(soql);

            if (stores.isEmpty()) {
                result.put('status', 'error');
                result.put('message', 'WebStore not found: ' + storeName);
                return result;
            }

            WebStore store = stores[0];
            Boolean cartAccessNow = (cartAccessField != null) ? (Boolean) store.get(cartAccessField) : true;
            Boolean preserveCartNow = (preserveCartField != null) ? (Boolean) store.get(preserveCartField) : true;
            Boolean alreadyEnabled = store.OptionsGuestBrowsingEnabled
                && store.OptionsGuestCheckoutEnabled
                && cartAccessNow
                && preserveCartNow;

            if (!alreadyEnabled) {
                store.OptionsGuestBrowsingEnabled = true;
                store.OptionsGuestCheckoutEnabled = true;
                if (cartAccessField != null) store.put(cartAccessField, true);
                if (preserveCartField != null) store.put(preserveCartField, true);
                update store;
            }

            result.put('status', 'success');
            result.put('message', alreadyEnabled
                ? 'Guest access already fully enabled'
                : 'Guest access enabled successfully');
            result.put('guestBrowsing', 'true');
            result.put('guestCheckout', 'true');
            result.put('cartAccessLwr', 'true');
            result.put('preserveGuestCartLwr', 'true');
            result.put('cartAccessFieldUsed', cartAccessField == null ? 'NONE_FOUND' : cartAccessField);
            result.put('preserveCartFieldUsed', preserveCartField == null ? 'NONE_FOUND' : preserveCartField);
            result.put('storeId', store.Id);
            return result;

        } catch (Exception e) {
            result.put('status', 'error');
            result.put('message', e.getMessage());
            return result;
        }
    }

    private static String pickFirstExistingField(Map<String, Schema.SObjectField> fieldMap, List<String> candidates) {
        for (String name : candidates) {
            if (fieldMap.containsKey(name.toLowerCase())) {
                return name;
            }
        }
        return null;
    }

    /**
     * Creates missing Commerce Store resources for a given WebStore
     * - ProductCatalog + WebStoreCatalog linkage
     * - Main Pricebook + Strikethrough Pricebook + WebStorePricebook linkages
     * - CommerceEntitlementPolicy
     * - BuyerGroup + WebStoreBuyerGroup linkage
     *
     * Idempotent - only creates missing resources, safe to run multiple times
     *
     * @param storeName Name of the WebStore to create resources for
     */
    public static void createCommerceStoreResources(String storeName) {
        System.debug('========================================');
        System.debug('Creating Commerce Store Resources');
        System.debug('Store: ' + storeName);
        System.debug('========================================');

        // Get WebStore
        List<WebStore> stores = [SELECT Id, Name FROM WebStore WHERE Name = :storeName LIMIT 1];
        if (stores.isEmpty()) {
            System.debug('❌ ERROR: WebStore "' + storeName + '" not found!');
            return;
        }
        WebStore store = stores[0];
        System.debug('✅ WebStore found: ' + store.Id);

        // ===== 1. CREATE PRODUCT CATALOG =====
        String catalogName = storeName + ' Catalog';
        List<ProductCatalog> existingCatalogs = [SELECT Id, Name FROM ProductCatalog WHERE Name = :catalogName LIMIT 1];

        ProductCatalog catalog;
        if (existingCatalogs.isEmpty()) {
            catalog = new ProductCatalog(Name = catalogName);
            insert catalog;
            System.debug('✅ Created ProductCatalog: ' + catalogName + ' (' + catalog.Id + ')');
        } else {
            catalog = existingCatalogs[0];
            System.debug('ℹ️  ProductCatalog already exists: ' + catalogName + ' (' + catalog.Id + ')');
        }

        // ===== 2. LINK CATALOG TO WEBSTORE =====
        List<WebStoreCatalog> existingLinks = [SELECT Id FROM WebStoreCatalog
                                               WHERE SalesStoreId = :store.Id
                                               AND ProductCatalogId = :catalog.Id LIMIT 1];
        if (existingLinks.isEmpty()) {
            WebStoreCatalog wsc = new WebStoreCatalog(
                SalesStoreId = store.Id,
                ProductCatalogId = catalog.Id
            );
            insert wsc;
            System.debug('✅ Linked Catalog to WebStore: ' + wsc.Id);
        } else {
            System.debug('ℹ️  Catalog already linked to WebStore');
        }

        // ===== 3. CREATE MAIN PRICEBOOK =====
        String priceBookName = storeName + ' Price Book';
        List<Pricebook2> existingPB = [SELECT Id, Name FROM Pricebook2 WHERE Name = :priceBookName LIMIT 1];

        Pricebook2 mainPB;
        if (existingPB.isEmpty()) {
            mainPB = new Pricebook2(Name = priceBookName, IsActive = true);
            insert mainPB;
            System.debug('✅ Created Pricebook: ' + priceBookName + ' (' + mainPB.Id + ')');
        } else {
            mainPB = existingPB[0];
            System.debug('ℹ️  Pricebook already exists: ' + priceBookName + ' (' + mainPB.Id + ')');
        }

        // ===== 4. CREATE STRIKETHROUGH PRICEBOOK =====
        String strikePBName = storeName + ' Strikethrough Price Book';
        List<Pricebook2> existingStrikePB = [SELECT Id, Name FROM Pricebook2 WHERE Name = :strikePBName LIMIT 1];

        Pricebook2 strikePB;
        if (existingStrikePB.isEmpty()) {
            strikePB = new Pricebook2(Name = strikePBName, IsActive = true);
            insert strikePB;
            System.debug('✅ Created Strikethrough Pricebook: ' + strikePBName + ' (' + strikePB.Id + ')');
        } else {
            strikePB = existingStrikePB[0];
            System.debug('ℹ️  Strikethrough Pricebook already exists: ' + strikePBName + ' (' + strikePB.Id + ')');
        }

        // ===== 4a. LINK MAIN PRICEBOOK TO WEBSTORE =====
        List<WebStorePricebook> existingWSPB = [SELECT Id FROM WebStorePricebook
                                                WHERE WebStoreId = :store.Id
                                                AND Pricebook2Id = :mainPB.Id LIMIT 1];
        if (existingWSPB.isEmpty()) {
            WebStorePricebook wspb = new WebStorePricebook(
                WebStoreId = store.Id,
                Pricebook2Id = mainPB.Id,
                IsActive = true
            );
            insert wspb;
            System.debug('✅ Linked Main Pricebook to WebStore: ' + wspb.Id);
        } else {
            System.debug('ℹ️  Main Pricebook already linked to WebStore');
        }

        // ===== 4b. LINK STRIKETHROUGH PRICEBOOK TO WEBSTORE =====
        List<WebStorePricebook> existingWSPBStrike = [SELECT Id FROM WebStorePricebook
                                                       WHERE WebStoreId = :store.Id
                                                       AND Pricebook2Id = :strikePB.Id LIMIT 1];
        if (existingWSPBStrike.isEmpty()) {
            WebStorePricebook wspbStrike = new WebStorePricebook(
                WebStoreId = store.Id,
                Pricebook2Id = strikePB.Id,
                IsActive = true
            );
            insert wspbStrike;
            System.debug('✅ Linked Strikethrough Pricebook to WebStore: ' + wspbStrike.Id);
        } else {
            System.debug('ℹ️  Strikethrough Pricebook already linked to WebStore');
        }

        // ===== 5. CREATE COMMERCE ENTITLEMENT POLICY =====
        String policyName = 'All Access for ' + storeName;
        List<CommerceEntitlementPolicy> existingPolicies = [SELECT Id, Name FROM CommerceEntitlementPolicy
                                                            WHERE Name = :policyName LIMIT 1];

        CommerceEntitlementPolicy policy;
        if (existingPolicies.isEmpty()) {
            policy = new CommerceEntitlementPolicy(
                Name = policyName,
                IsActive = true,
                CanViewProduct = true,
                CanViewPrice = true
            );
            insert policy;
            System.debug('✅ Created CommerceEntitlementPolicy: ' + policyName + ' (' + policy.Id + ')');
        } else {
            policy = existingPolicies[0];
            System.debug('ℹ️  CommerceEntitlementPolicy already exists: ' + policyName + ' (' + policy.Id + ')');
        }

        // ===== 6. CREATE BUYER GROUP =====
        String buyerGroupName = storeName + ' Buyer Group';
        List<BuyerGroup> existingBG = [SELECT Id, Name FROM BuyerGroup WHERE Name = :buyerGroupName LIMIT 1];

        BuyerGroup buyerGroup;
        if (existingBG.isEmpty()) {
            buyerGroup = new BuyerGroup(Name = buyerGroupName);
            insert buyerGroup;
            System.debug('✅ Created BuyerGroup: ' + buyerGroupName + ' (' + buyerGroup.Id + ')');
        } else {
            buyerGroup = existingBG[0];
            System.debug('ℹ️  BuyerGroup already exists: ' + buyerGroupName + ' (' + buyerGroup.Id + ')');
        }

        // ===== 7. LINK BUYER GROUP TO WEBSTORE =====
        List<WebStoreBuyerGroup> existingWSBG = [SELECT Id FROM WebStoreBuyerGroup
                                                 WHERE WebStoreId = :store.Id
                                                 AND BuyerGroupId = :buyerGroup.Id LIMIT 1];
        if (existingWSBG.isEmpty()) {
            WebStoreBuyerGroup wsbg = new WebStoreBuyerGroup(
                WebStoreId = store.Id,
                BuyerGroupId = buyerGroup.Id
            );
            insert wsbg;
            System.debug('✅ Linked BuyerGroup to WebStore: ' + wsbg.Id);
        } else {
            System.debug('ℹ️  BuyerGroup already linked to WebStore');
        }

        System.debug('');
        System.debug('========================================');
        System.debug('✅ Commerce Store Resources Complete');
        System.debug('========================================');
        System.debug('Store: ' + store.Name + ' (' + store.Id + ')');
        System.debug('Catalog: ' + catalog.Name + ' (' + catalog.Id + ')');
        System.debug('Main Pricebook: ' + mainPB.Name + ' (' + mainPB.Id + ')');
        System.debug('Strikethrough Pricebook: ' + strikePB.Name + ' (' + strikePB.Id + ')');
        System.debug('Entitlement Policy: ' + policy.Name + ' (' + policy.Id + ')');
        System.debug('Buyer Group: ' + buyerGroup.Name + ' (' + buyerGroup.Id + ')');
        System.debug('========================================');
    }

    /**
     * Assigns Guest Buyer Account to Buyer Groups for a Commerce store
     * - Creates "{storeName} Buyer Group" if missing
     * - Assigns Guest Buyer Account to "{storeName} Guest Buyer Group"
     * - Assigns Guest Buyer Account to "{storeName} Buyer Group"
     *
     * Idempotent - safe to run multiple times
     *
     * @param storeName Name of the WebStore (e.g., 'PulseSync')
     */
    public static void assignGuestBuyerToGroups(String storeName) {
        System.debug('========================================');
        System.debug('Assigning Guest Buyer to Buyer Groups');
        System.debug('Store: ' + storeName);
        System.debug('========================================');

        // Get WebStore
        List<WebStore> stores = [SELECT Id, Name FROM WebStore WHERE Name = :storeName LIMIT 1];
        if (stores.isEmpty()) {
            System.debug('❌ ERROR: WebStore "' + storeName + '" not found!');
            return;
        }
        WebStore store = stores[0];
        System.debug('✅ WebStore: ' + store.Id);

        // Get Guest Buyer Profile (GuestBuyerProfile object, used as BuyerId in BuyerGroupMember)
        String guestProfileName = storeName + ' Guest Buyer Profile';
        List<GuestBuyerProfile> guestProfiles = [SELECT Id, Name FROM GuestBuyerProfile
                                                  WHERE Name = :guestProfileName LIMIT 1];
        if (guestProfiles.isEmpty()) {
            System.debug('❌ ERROR: ' + guestProfileName + ' not found!');
            return;
        }
        GuestBuyerProfile guestAccount = guestProfiles[0];
        System.debug('✅ Guest Buyer Profile: ' + guestAccount.Id);

        // Get or Create "<storeName> Buyer Group" (main buyer group)
        String mainGroupName = storeName + ' Buyer Group';
        List<BuyerGroup> storeBuyerGroups = [SELECT Id, Name FROM BuyerGroup
                                              WHERE Name = :mainGroupName LIMIT 1];
        BuyerGroup storeBuyerGroup;
        if (storeBuyerGroups.isEmpty()) {
            storeBuyerGroup = new BuyerGroup(Name = mainGroupName);
            insert storeBuyerGroup;
            System.debug('✅ Created ' + mainGroupName + ': ' + storeBuyerGroup.Id);
        } else {
            storeBuyerGroup = storeBuyerGroups[0];
            System.debug('ℹ️  ' + mainGroupName + ' already exists: ' + storeBuyerGroup.Id);
        }

        // Assign Guest Account to <storeName> Buyer Group
        List<BuyerGroupMember> storeLink = [SELECT Id FROM BuyerGroupMember
                                             WHERE BuyerGroupId = :storeBuyerGroup.Id
                                             AND BuyerId = :guestAccount.Id LIMIT 1];
        if (storeLink.isEmpty()) {
            BuyerGroupMember member2 = new BuyerGroupMember(
                BuyerGroupId = storeBuyerGroup.Id,
                BuyerId = guestAccount.Id
            );
            insert member2;
            System.debug('✅ Assigned Guest Account to ' + mainGroupName + ': ' + member2.Id);
        } else {
            System.debug('ℹ️  Guest Account already in ' + mainGroupName);
        }

        System.debug('');
        System.debug('========================================');
        System.debug('✅ Guest Buyer Assignment Complete');
        System.debug('========================================');
        System.debug('Guest Buyer Profile: ' + guestProfileName + ' (' + guestAccount.Id + ')');
        System.debug('  → Assigned to: ' + mainGroupName + ' (' + storeBuyerGroup.Id + ')');
        System.debug('========================================');
    }

    /**
     * Enables an Account as a Buyer and assigns it to a Buyer Group for the store
     * - Creates BuyerAccount record (enables as Buyer) if missing
     * - Assigns the Account to "{storeName} Buyer Group"
     *
     * Idempotent - safe to run multiple times
     *
     * @param accountName Name of the Account to enable as Buyer (e.g., 'Mark Smith')
     * @param storeName Name of the WebStore (e.g., 'PulseSync')
     */
    public static void enableAccountAsBuyer(String accountName, String storeName) {
        System.debug('========================================');
        System.debug('Enable Account as Buyer & Assign to Group');
        System.debug('Account: ' + accountName);
        System.debug('Store: ' + storeName);
        System.debug('========================================');

        // Get the Account — Health Cloud Person Account only.
        // Data seeding can create two Person Accounts with the same Name (a legacy
        // non-HC seed row + the Health Cloud row). Without the isHealthCloudRecord__pc
        // filter, this SOQL can bind the BuyerAccount to the wrong Account — the one
        // the community User's Contact does NOT point at — which leaves the community
        // login without buyer/pricing/category entitlement (storefront tabs render empty).
        List<Account> accounts = [
            SELECT Id, Name
            FROM Account
            WHERE Name = :accountName
              AND IsPersonAccount = true
              AND isHealthCloudRecord__pc = true
            LIMIT 1
        ];
        if (accounts.isEmpty()) {
            System.debug('❌ ERROR: Health Cloud Person Account "' + accountName + '" (isHealthCloudRecord__pc=true) not found!');
            return;
        }
        Account acc = accounts[0];
        System.debug('✅ Account: ' + acc.Name + ' (' + acc.Id + ')');

        // Check if already enabled as buyer
        List<BuyerAccount> existingBuyers = [SELECT Id, BuyerId FROM BuyerAccount
                                              WHERE BuyerId = :acc.Id LIMIT 1];

        BuyerAccount buyerAcc;
        if (existingBuyers.isEmpty()) {
            buyerAcc = new BuyerAccount(
                BuyerId = acc.Id,
                Name = acc.Name,
                IsActive = true
            );
            insert buyerAcc;
            System.debug('✅ Enabled as Buyer: ' + buyerAcc.Id);
        } else {
            buyerAcc = existingBuyers[0];
            System.debug('ℹ️  Already enabled as Buyer: ' + buyerAcc.Id);
        }

        // Get the Buyer Group
        String buyerGroupName = storeName + ' Buyer Group';
        List<BuyerGroup> buyerGroups = [SELECT Id, Name FROM BuyerGroup
                                         WHERE Name = :buyerGroupName LIMIT 1];
        if (buyerGroups.isEmpty()) {
            System.debug('❌ ERROR: Buyer Group "' + buyerGroupName + '" not found!');
            return;
        }
        BuyerGroup buyerGroup = buyerGroups[0];
        System.debug('✅ Buyer Group: ' + buyerGroup.Name + ' (' + buyerGroup.Id + ')');

        // Check if already assigned to buyer group
        List<BuyerGroupMember> existingMembers = [SELECT Id FROM BuyerGroupMember
                                                   WHERE BuyerGroupId = :buyerGroup.Id
                                                   AND BuyerId = :acc.Id LIMIT 1];

        if (existingMembers.isEmpty()) {
            BuyerGroupMember member = new BuyerGroupMember(
                BuyerGroupId = buyerGroup.Id,
                BuyerId = acc.Id
            );
            insert member;
            System.debug('✅ Assigned to Buyer Group: ' + member.Id);
        } else {
            System.debug('ℹ️  Already assigned to Buyer Group: ' + existingMembers[0].Id);
        }

        System.debug('');
        System.debug('========================================');
        System.debug('✅ Account Enabled as Buyer and Assigned');
        System.debug('========================================');
        System.debug('Account: ' + acc.Name + ' (' + acc.Id + ')');
        System.debug('Buyer Group: ' + buyerGroup.Name + ' (' + buyerGroup.Id + ')');
        System.debug('========================================');
    }

    /**
     * Fetches contentKeys for a list of CMS Workspace images by name
     * - Queries ManagedContent SObject by Name
     * - Returns latest ContentKey (newest CreatedDate) for each image
     * - Logs CONTENT_KEY:{name}={key} for parsing by external tools (e.g., PowerShell)
     *
     * @param imageNames List of CMS image names to look up
     * @return Map of imageName -> contentKey (or 'NOT_FOUND' if missing)
     */
    public static Map<String, String> getCMSImageContentKeys(List<String> imageNames) {
        System.debug('========================================');
        System.debug('Fetching CMS Image contentKeys');
        System.debug('========================================');

        Map<String, String> nameToKey = new Map<String, String>();

        if (imageNames == null || imageNames.isEmpty()) {
            System.debug('❌ No image names provided');
            return nameToKey;
        }

        // Query all images at once
        List<ManagedContent> contents = [SELECT Id, Name, ContentKey, ContentTypeFullyQualifiedName
                                          FROM ManagedContent
                                          WHERE Name IN :imageNames
                                          ORDER BY CreatedDate DESC];

        // Map names to contentKeys (latest first wins due to ORDER BY)
        for (ManagedContent c : contents) {
            if (!nameToKey.containsKey(c.Name)) {
                nameToKey.put(c.Name, c.ContentKey);
            }
        }

        // Log results
        System.debug('');
        System.debug('=== RESULTS ===');
        for (String imgName : imageNames) {
            if (nameToKey.containsKey(imgName)) {
                System.debug('CONTENT_KEY:' + imgName + '=' + nameToKey.get(imgName));
                System.debug('✅ ' + imgName + ': ' + nameToKey.get(imgName));
            } else {
                System.debug('CONTENT_KEY:' + imgName + '=NOT_FOUND');
                System.debug('❌ ' + imgName + ': NOT FOUND - Upload to CMS Workspace and publish first');
                nameToKey.put(imgName, 'NOT_FOUND');
            }
        }
        System.debug('========================================');

        return nameToKey;
    }

    /**
     * Enables Guest Buyer Access for a Commerce Store
     * - Creates "{storeName} Guest Buyer Group" if missing
     * - Links Guest Buyer Group to WebStore via WebStoreBuyerGroup junction
     *
     * Idempotent - safe to run multiple times
     *
     * @param storeName Name of the WebStore (e.g., 'PulseSync')
     */
    public static void enableGuestAccess(String storeName) {
        System.debug('========================================');
        System.debug('Enable Guest Buyer Access');
        System.debug('Store: ' + storeName);
        System.debug('========================================');

        // Get WebStore
        List<WebStore> stores = [SELECT Id, Name FROM WebStore WHERE Name = :storeName LIMIT 1];
        if (stores.isEmpty()) {
            System.debug('❌ ERROR: WebStore "' + storeName + '" not found!');
            return;
        }
        WebStore store = stores[0];
        System.debug('✅ WebStore: ' + store.Id);

        // Get or Create Guest Buyer Group
        String guestGroupName = storeName + ' Guest Buyer Group';
        List<BuyerGroup> existingGroups = [SELECT Id, Name FROM BuyerGroup
                                            WHERE Name = :guestGroupName LIMIT 1];

        BuyerGroup guestGroup;
        if (existingGroups.isEmpty()) {
            guestGroup = new BuyerGroup(Name = guestGroupName);
            insert guestGroup;
            System.debug('✅ Created Guest BuyerGroup: ' + guestGroup.Id);
        } else {
            guestGroup = existingGroups[0];
            System.debug('ℹ️  Guest BuyerGroup already exists: ' + guestGroup.Id);
        }

        // Link BuyerGroup to WebStore
        List<WebStoreBuyerGroup> existingLinks = [SELECT Id FROM WebStoreBuyerGroup
                                                   WHERE WebStoreId = :store.Id
                                                   AND BuyerGroupId = :guestGroup.Id LIMIT 1];

        if (existingLinks.isEmpty()) {
            WebStoreBuyerGroup link = new WebStoreBuyerGroup(
                WebStoreId = store.Id,
                BuyerGroupId = guestGroup.Id
            );
            insert link;
            System.debug('✅ Linked Guest BuyerGroup to WebStore: ' + link.Id);
        } else {
            System.debug('ℹ️  Link already exists: ' + existingLinks[0].Id);
        }

        System.debug('');
        System.debug('========================================');
        System.debug('✅ Guest Buyer Access Enabled');
        System.debug('========================================');
        System.debug('WebStore: ' + store.Name + ' (' + store.Id + ')');
        System.debug('BuyerGroup: ' + guestGroupName + ' (' + guestGroup.Id + ')');
        System.debug('========================================');
    }

    /**
     * Print guest browsing status for a Commerce store
     * This method is called from scripts/apex/enableGuestBrowsing.apex
     */
    public static void printGuestBrowsingStatus(String storeName) {
        Map<String, String> result = enableGuestBrowsing(storeName);

        System.debug('========================================');
        System.debug('🛒 Commerce Guest Access Configuration');
        System.debug('========================================');
        System.debug('');
        System.debug('Store: ' + storeName);
        System.debug('Status: ' + result.get('status'));
        System.debug('');

        if (result.get('status') == 'success') {
            System.debug('✅ ' + result.get('message'));
            System.debug('');
            System.debug('Settings:');
            System.debug('  - Guest Browsing: ' + result.get('guestBrowsing'));
            System.debug('  - Guest Checkout (LWR): ' + result.get('guestCheckout'));
            System.debug('  - Cart access (LWR): ' + result.get('cartAccessLwr')
                + '  [field: ' + result.get('cartAccessFieldUsed') + ']');
            System.debug('  - Preserve guest carts (LWR): ' + result.get('preserveGuestCartLwr')
                + '  [field: ' + result.get('preserveCartFieldUsed') + ']');
            if (result.containsKey('storeId')) {
                System.debug('  - Store ID: ' + result.get('storeId'));
            }
        } else {
            System.debug('❌ Error: ' + result.get('message'));
        }

        System.debug('');
        System.debug('========================================');
    }
}