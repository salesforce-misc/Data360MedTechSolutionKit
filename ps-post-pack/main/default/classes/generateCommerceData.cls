/**
 * @description       : 
 * @author            : ChangeMeIn@UserSettingsUnder.SFDoc
 * @group             : 
 * @last modified on  : 03-27-2026
 * @last modified by  : ChangeMeIn@UserSettingsUnder.SFDoc
**/
public without sharing class generateCommerceData {
    
    public static void createCommercePolicy(){
     
        //fetch the store catalog
        ProductCatalog prodCatalog = [SELECT Id, Name FROM ProductCatalog WHERE Name ='PulseSync Catalog' LIMIT 1];
		system.debug('prodCatalog:'+prodCatalog);
        
        //creation of Product Category
        List<String> categoryNameList = new List<String>{'Pacemaker','Home Monitor','Remote App','Pacemaker Accessories'};
        Set<String> existingCategoryNames = new Set<String>();
        for(ProductCategory pc : [SELECT Name FROM ProductCategory
                                   WHERE CatalogId = :prodCatalog.Id
                                   AND Name IN :categoryNameList]){
            existingCategoryNames.add(pc.Name);
        }
        List<ProductCategory> pCategoryList = new List<ProductCategory>();
        for(String cName : categoryNameList){
            if(!existingCategoryNames.contains(cName)){
                pCategoryList.add(new ProductCategory(
                    Name = cName, IsNavigational = true, CatalogId = prodCatalog.Id));
            }
        }
        if(!pCategoryList.isEmpty()){
            insert pCategoryList;
        }
        system.debug('Created Category:'+pCategoryList);
        
        //uncheck show is menu checkbox if product category present
        List<ProductCategory> categoryNameProduct = [Select id,name,IsNavigational,CatalogId from ProductCategory where
                                               Name = 'Products' And CatalogId =:prodCatalog.Id limit 1];
        if(!categoryNameProduct.isEmpty()){
        categoryNameProduct[0].IsNavigational = false;
        update categoryNameProduct[0];
        system.debug('categoryNameProduct:'+categoryNameProduct[0]);
        }
     
        
         // Define Category -> Families mapping
        Map<String, Set<String>> categoryToFamiliesMap = new Map<String, Set<String>>{
        'Pacemaker'       => new Set<String>{'Pacemaker'},
       'Home Monitor'  => new Set<String>{'Remote Monitor'},
      'Remote App'    => new Set<String>{'Remote Monitoring Mobile App'},
       'Pacemaker Accessories'    => new Set<String>{'Pacing Accessories'}
    };
        
        Set<String> allFamilies = new Set<String>();
        Map<String, String> familyToCategoryMap = new Map<String, String>();
        for(String catName : categoryToFamiliesMap.keySet()){
            Set<String> famSet = categoryToFamiliesMap.get(catName);
            allFamilies.addAll(famSet);
            for(String fam : famSet){
                familyToCategoryMap.put(fam, catName); // for ProductCategory lookup
            }
            
        }
       System.debug(allFamilies); 
          
       //  Query all products for these families
        List<Product2> products = [SELECT Id, Name, Family FROM Product2  WHERE Family IN ('Pacemaker','Remote Monitor','Remote Monitoring Mobile App','Pacing Accessories')];
        Set<Id> productIds = new Set<Id>();
        for(Product2 p : products){
            productIds.add(p.Id);
        }
        
        /// Fetch Commerce Entitlement Policy
       CommerceEntitlementPolicy cmrceentiltmntPolicy = [SELECT Id  FROM CommerceEntitlementPolicy WHERE Name = 'All Access for PulseSync' LIMIT 1];
       system.debug('cmrceentiltmntPolicy:'+cmrceentiltmntPolicy);
        
        // Existing CommerceEntitlementProducts
		Set<Id> existingCEPProducts = new Set<Id>();
       List<CommerceEntitlementProduct> commerceEntProductList = [Select id,ProductId,PolicyId from
                  CommerceEntitlementProduct where ProductId IN :productIds AND PolicyId =:cmrceentiltmntPolicy.Id];
        system.debug('commerceEntProductList:'+commerceEntProductList);
        for(CommerceEntitlementProduct cm: commerceEntProductList){
            existingCEPProducts.add(cm.ProductId);
        }
        
        
        //Get Product Category and store under map
        Map<String, Id> categoryNameToId = new Map<String, Id>();
        List<ProductCategory> prodCategoryList =[SELECT Id, Name, Catalog.Name,CatalogId FROM ProductCategory
                                                 Where CatalogId =:prodCatalog.Id];
        for(ProductCategory pc:prodCategoryList){
            categoryNameToId.put(pc.Name, pc.Id);
        }
        
        //  Existing ProductCategoryProduct combinations
        Set<String> existingPCPSet = new Set<String>();
        List<ProductCategoryProduct> productCatgProductList = [Select id,name,ProductId,ProductCategoryId
                                                               from ProductCategoryProduct where ProductId IN :productIds];
        
        for(ProductCategoryProduct cp:productCatgProductList ){
            existingPCPSet.add(cp.ProductId);
        }
        
        //creation of new commerce entitlement policy and product category
        List<CommerceEntitlementProduct> commercePolicyList = new List<CommerceEntitlementProduct>();
        List<ProductCategoryProduct> newPCPs = new List<ProductCategoryProduct>();
        
        for(product2 pId : products){
            //creation of commerce policy
            if(!existingCEPProducts.contains(pId.Id)){
                commercePolicyList.add(new CommerceEntitlementProduct(
                    ProductId = pId.Id,
                    PolicyId = cmrceentiltmntPolicy.Id
                ));
            }
            
            //creation of product category
            
            String categoryName = familyToCategoryMap.get(pId.Family);
            if(categoryName != null && categoryNameToId.containsKey(categoryName)){
                String comboKey = String.valueOf(pId.Id) + '-' + String.valueOf(categoryNameToId.get(categoryName));
                if(!existingPCPSet.contains(comboKey)){
                    newPCPs.add(new ProductCategoryProduct(
                        ProductId = pId.Id,
                        ProductCategoryId = categoryNameToId.get(categoryName)
                    ));
                }
            }
        }
        if(!commercePolicyList.isEmpty()){
            insert commercePolicyList;
            system.debug('commercePolicyList'+commercePolicyList);   
        }
        
        if(!newPCPs.isEmpty()){
            insert newPCPs;
            system.debug('newPCPs'+newPCPs);   
        }
    }     
    
    //Creation of Pricebook for Store
    public static void insertionPricebookStore(){
        // Get old pricebook
        Pricebook2 oldPB = [ SELECT Id, Name FROM Pricebook2 WHERE Name = 'MedTech Pricebook' LIMIT 1];
        system.debug('oldPb:'+oldPB);
        
        //get commerce store pricebook
        Pricebook2 newPB = [SELECT Id, Name FROM Pricebook2 WHERE Name LIKE 'PulseSync Price Book' LIMIT 1];
        system.debug('newPB:'+newPB);
            
            // Fetch entries from old pricebook
        List<PricebookEntry> oldEntries = [ SELECT Product2Id, UnitPrice, Name, IsActive, UseStandardPrice
                		            FROM PricebookEntry  WHERE Pricebook2Id = :oldPB.Id AND
                                            Product2.Family IN ('Pacemaker', 'Remote Monitor', 'Remote Monitoring Mobile App', 'Pacing Accessories')];
        system.debug('oldEntries:'+oldEntries);

        
		//Prepare new pricebook entries 
        List<PricebookEntry> newEntries = new List<PricebookEntry>();
        
        for(PricebookEntry oldPBE : oldEntries){
            PricebookEntry newPBE = new PricebookEntry();
            newPBE.Pricebook2Id     = newPB.Id;           // New Pricebook
            newPBE.Product2Id       = oldPBE.Product2Id;  // Same Product
            newPBE.UnitPrice        = oldPBE.UnitPrice;   // Same Price
            newPBE.IsActive         = oldPBE.IsActive;    // Same active status
            newPBE.UseStandardPrice = false;
            
            newEntries.add(newPBE);
        }
        
 		//Insert new pricebook entries
        if(!newEntries.isEmpty()){
            insert newEntries;
        }
        
        System.debug('Inserted records into new pricebook (' + newPB.Name + '): ' + newEntries.size());
    }
    
}
