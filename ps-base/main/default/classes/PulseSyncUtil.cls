/**
 * @description       : 
 * @author            : ChangeMeIn@UserSettingsUnder.SFDoc
 * @group             : 
 * @last modified on  : 04-07-2026
 * @last modified by  : ChangeMeIn@UserSettingsUnder.SFDoc
**/
global class PulseSyncUtil {

    global class Request {
        @InvocableVariable
        global Id ContactId; // contains AccountId
    }

    global class promptResponse {
        @InvocableVariable
        global String Prompt;
    }

    @InvocableMethod(
        label='Get Contact'
        description='Returns a contact name to prompt'
        category='Prompt'
    )
    global static List<promptResponse> invoke(List<Request> requests) {
        System.debug('## requests = ' + requests);

        List<promptResponse> promptResponses = new List<promptResponse>();

        if ((requests == null && requests.isEmpty()) || requests == null || requests.isEmpty()) {
            return promptResponses;
        }

        Set<Id> accountIdSet = new Set<Id>();
        for (Request req : requests) {
            if (req.ContactId != null) {
                accountIdSet.add(req.ContactId);
            }
        }
        System.debug('accountIdSet:' + accountIdSet);

        Map<Id, Contact> accountToContactMap = new Map<Id, Contact>();
        List<Contact> contactList = [
            SELECT Id, Name, AccountId
            FROM Contact
            WHERE AccountId IN :accountIdSet
            LIMIT 1
        ];

        for (Contact c : contactList) {
            if (!accountToContactMap.containsKey(c.AccountId)) {
                accountToContactMap.put(c.AccountId, c); // Key = AccountId
            }
        }
        System.debug('accountToContactMap:' + accountToContactMap);

        for (Request req : requests) {
            promptResponse pr = new promptResponse();
            Contact cont = accountToContactMap.get(req.ContactId); // here is the accountId
            String promptText = ' ';

            if (cont != null) {
                promptText = cont.Name;
            }

            pr.Prompt = promptText;
            promptResponses.add(pr);
        }

        System.debug('promptResponses:' + promptResponses);
        return promptResponses;
    }

     /* =====================================================
       CONSTANTS
       ===================================================== */
    @TestVisible
    private static final Set<String> PERM_SET_LICENSES = new Set<String>{
        'AgentforceServiceAgentUserPsl',
        'EinsteinGPTPromptTemplatesPsl', 
        'GenieDataPlatformStarterPsl'               
    };

    private static final Set<String> PERM_SETS = new Set<String>{
        'AgentforceServiceAgentSecureBase',
        'AgentforceServiceAgentBase',
        'AgentforceServiceAgentUser',
        'GenieUserEnhancedSecurity',
        'PulseSyncCustomPS',
        'Agentforce_Service_Agent553366132_Permissions' 
    };

    private static final List<String> COPY_FIELDS = new List<String>{
        'Last_Transmission__c',
        'Battery_Score__c',
        'Pacing_Performance_Score__c',
        'Unified_Individual_Id__c',
        'Atrial_Risk_Score__c'
    };

    private static final String COPY_PERMISSION_SET_LABEL = 'Customer 360 Data Platform Integration';
    private static final String CONTACT_OBJECT = 'Contact';

    /* =====================================================
       1. ACTIVATE STANDARD PRICEBOOK (SAFE)
       ===================================================== */
    public static void activateStandardPricebook() {
        Id stdPricebookId;

        if (Test.isRunningTest()) {
            stdPricebookId = Test.getStandardPricebookId();
        } else {
            List<Pricebook2> pbList = [
                SELECT Id
                FROM Pricebook2
                WHERE IsStandard = true
                LIMIT 1
            ];
            if (pbList.isEmpty()) {
                return;
            }
            stdPricebookId = pbList[0].Id;
        }

        List<Pricebook2> pb = [
            SELECT Id, IsActive
            FROM Pricebook2
            WHERE Id = :stdPricebookId
            LIMIT 1
        ];

        if (!pb.isEmpty() && !pb[0].IsActive) {
            pb[0].IsActive = true;
            update pb[0];
        }
    }

    /* =====================================================
       2. EXPERIENCE SITE USER CREATION (SAFE)
       ===================================================== */
    public static void expSiteUserCreation() {
        List<Contact> contactRecord = [
            SELECT Id, FirstName, LastName, Email
            FROM Contact
            WHERE Name = 'Mark Smith'
            AND isHealthCloudRecord__c = true
            LIMIT 1
        ];

        if (contactRecord.isEmpty()) {
            return;
        }

        Profile prof;

        if (Test.isRunningTest()) {
            prof = [SELECT Id FROM Profile LIMIT 1];
        } else {
            List<Profile> profList = [
                SELECT Id
                FROM Profile
                WHERE Name = 'Customer Community Plus Login User'
                LIMIT 1
            ];
            if (profList.isEmpty()) {
                return;
            }
            prof = profList[0];
        }

        String uniqueString = String.valueOf(DateTime.now().getTime());
        String emailAddress = contactRecord[0].Email;

        User usr = new User(
            FirstName = 'Mark',
            LastName = 'Smith',
            Email = emailAddress,
            Username = emailAddress + 'pulse' + uniqueString,
            Alias = 'ms' + uniqueString.substring(uniqueString.length() - 3),
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'GMT',
            LanguageLocaleKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            ProfileId = prof.Id,
            ContactId = contactRecord[0].Id
        );

        insert usr;

        // Enable portal
        User userRecord = [
            SELECT Id, IsPortalEnabled
            FROM User
            WHERE ContactId = :contactRecord[0].Id
            LIMIT 1
        ];

        if (userRecord != null) {
            userRecord.IsPortalEnabled = true;
            update userRecord;
        }

        /* Permission Set Assignment */
        List<PermissionSet> permSets;

        if (Test.isRunningTest()) {
            permSets = [SELECT Id FROM PermissionSet LIMIT 1];
        } else {
            permSets = [
                SELECT Id
                FROM PermissionSet
                WHERE Name IN ('B2BBuyer')
            ];
        }

        if (!permSets.isEmpty()) {
            List<PermissionSetAssignment> psaList = new List<PermissionSetAssignment>();

            for (PermissionSet ps : permSets) {
                psaList.add(new PermissionSetAssignment(
                    AssigneeId = usr.Id,
                    PermissionSetId = ps.Id
                ));
            }

            insert psaList;
        }

        System.setPassword(usr.Id, 'orgfarm123');
    }

    /* =====================================================
       3. FIELD + OBJECT PERMISSIONS (FIXED DUPLICATES)
       ===================================================== */
  @future
    public static void assignCopyFieldPermission() {
        List<PermissionSet> psList;
    
        if (Test.isRunningTest()) {
            psList = [SELECT Id FROM PermissionSet LIMIT 1];
        } else {
            psList = [
                SELECT Id
                FROM PermissionSet
                WHERE Label = :COPY_PERMISSION_SET_LABEL
                LIMIT 1
            ];
        }
    
        System.debug('## psList = ' + psList);
    
        if (psList.isEmpty()) {
            return;
        }
    
        Id permSetId = psList[0].Id;
        System.debug('## permSetId = ' + permSetId);
    
        // -------------------------------
        // FIELD PERMISSIONS
        // -------------------------------
        Map<String, FieldPermissions> existingFieldPerms = new Map<String, FieldPermissions>();
        for (FieldPermissions fp : [
            SELECT Id, Field, PermissionsRead, PermissionsEdit
            FROM FieldPermissions
            WHERE ParentId = :permSetId
            AND SobjectType = :CONTACT_OBJECT
        ]) {
            existingFieldPerms.put(fp.Field, fp);
        }
    
        System.debug('## existingFieldPerms = ' + existingFieldPerms);
    
        List<FieldPermissions> fieldPermsToInsert = new List<FieldPermissions>();
        List<FieldPermissions> fieldPermsToUpdate = new List<FieldPermissions>();
    
        for (String fieldName : COPY_FIELDS) {
            String fullFieldName = CONTACT_OBJECT + '.' + fieldName;
    
            if (existingFieldPerms.containsKey(fullFieldName)) {
                FieldPermissions existingFp = existingFieldPerms.get(fullFieldName);
                Boolean needsUpdate = false;
    
                if (existingFp.PermissionsRead != true) {
                    existingFp.PermissionsRead = true;
                    needsUpdate = true;
                }
    
                if (existingFp.PermissionsEdit != true) {
                    existingFp.PermissionsEdit = true;
                    needsUpdate = true;
                }
    
                if (needsUpdate) {
                    fieldPermsToUpdate.add(existingFp);
                }
            } else {
                fieldPermsToInsert.add(new FieldPermissions(
                    ParentId = permSetId,
                    SobjectType = CONTACT_OBJECT,
                    Field = fullFieldName,
                    PermissionsRead = true,
                    PermissionsEdit = true
                ));
            }
        }
    
        System.debug('## fieldPermsToInsert = ' + fieldPermsToInsert);
        System.debug('## fieldPermsToUpdate = ' + fieldPermsToUpdate);
    
        if (!fieldPermsToInsert.isEmpty()) {
            insert fieldPermsToInsert;
        }
    
        if (!fieldPermsToUpdate.isEmpty()) {
            update fieldPermsToUpdate;
        }
    
        // -------------------------------
        // OBJECT PERMISSIONS
        // -------------------------------
        Map<String, ObjectPermissions> existingObjPermsMap = new Map<String, ObjectPermissions>();
        for (ObjectPermissions op : [
            SELECT Id,
                   SObjectType,
                   PermissionsRead,
                   PermissionsCreate,
                   PermissionsEdit,
                   PermissionsDelete,
                   PermissionsViewAllRecords,
                   PermissionsModifyAllRecords
            FROM ObjectPermissions
            WHERE ParentId = :permSetId
            AND SObjectType IN ('Contact', 'Account')
        ]) {
            existingObjPermsMap.put(op.SObjectType, op);
        }
    
        System.debug('## existingObjPermsMap = ' + existingObjPermsMap);
    
        List<ObjectPermissions> objPermsToInsert = new List<ObjectPermissions>();
        List<ObjectPermissions> objPermsToUpdate = new List<ObjectPermissions>();
    
        for (String objName : new List<String>{'Contact', 'Account'}) {
            if (existingObjPermsMap.containsKey(objName)) {
                ObjectPermissions existingOp = existingObjPermsMap.get(objName);
                Boolean needsUpdate = false;
    
                // Dependency order matters
                if (existingOp.PermissionsRead != true) {
                    existingOp.PermissionsRead = true;
                    needsUpdate = true;
                }
    
                if (existingOp.PermissionsEdit != true) {
                    existingOp.PermissionsEdit = true;
                    needsUpdate = true;
                }
    
                if (existingOp.PermissionsCreate != true) {
                    existingOp.PermissionsCreate = true;
                    needsUpdate = true;
                }
    
                if (existingOp.PermissionsDelete != true) {
                    existingOp.PermissionsDelete = true;
                    needsUpdate = true;
                }
    
                if (existingOp.PermissionsViewAllRecords != true) {
                    existingOp.PermissionsViewAllRecords = true;
                    needsUpdate = true;
                }
    
                if (existingOp.PermissionsModifyAllRecords != true) {
                    existingOp.PermissionsModifyAllRecords = true;
                    needsUpdate = true;
                }
    
                // Only update if something was missing
                if (needsUpdate) {
                    objPermsToUpdate.add(existingOp);
                }
            } else {
                objPermsToInsert.add(new ObjectPermissions(
                    ParentId = permSetId,
                    SObjectType = objName,
                    PermissionsRead = true,
                    PermissionsEdit = true,
                    PermissionsCreate = true,
                    PermissionsDelete = true,
                    PermissionsViewAllRecords = true,
                    PermissionsModifyAllRecords = true
                ));
            }
        }
    
        System.debug('## objPermsToInsert = ' + objPermsToInsert);
        System.debug('## objPermsToUpdate = ' + objPermsToUpdate);
    
        if (!objPermsToInsert.isEmpty()) {
            insert objPermsToInsert;
        }
    
        if (!objPermsToUpdate.isEmpty()) {
            update objPermsToUpdate;
        }
       PulseSyncUtil.contactUpdationIntoAsset();
    }

   

    /* =====================================================
       4. AGENT USER SETUP
       ===================================================== */
    public static void setup() {
        Profile p;

        if (Test.isRunningTest()) {
            p = [SELECT Id FROM Profile LIMIT 1];
        } else {
            List<Profile> profileList = [
                SELECT Id
                FROM Profile
                WHERE Name = 'Einstein Agent User'
                LIMIT 1
            ];
            if (profileList.isEmpty()) {
                return;
            }
            p = profileList[0];
        }

        String unique = String.valueOf(DateTime.now().getTime());
        String aliasSuffix = unique.length() >= 3
            ? unique.substring(unique.length() - 3)
            : unique;

        User u = new User(
            FirstName = 'Einstein',
            LastName = 'User',
            Email = 'eagent' + unique + '@test.com',
            Username = 'eagent' + unique + '@test.com',
            Alias = ('ea' + aliasSuffix).left(8),
            TimeZoneSidKey = 'America/New_York',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId = p.Id
        );

        insert u;
        System.debug('Created user: ' + u.Username);
        System.debug('Created user email: ' + u.Email);

        Set<Id> targetPslIds = getPermissionSetLicenseIds();

        if (!targetPslIds.isEmpty()) {
            Set<Id> alreadyAssignedPslIds = new Set<Id>();
            for (PermissionSetLicenseAssign userPsla : [
                SELECT PermissionSetLicenseId
                FROM PermissionSetLicenseAssign
                WHERE AssigneeId = :u.Id
                  AND PermissionSetLicenseId IN :targetPslIds
            ]) {
                alreadyAssignedPslIds.add(userPsla.PermissionSetLicenseId);
            }

            targetPslIds.removeAll(alreadyAssignedPslIds);

            if (!targetPslIds.isEmpty()) {
                List<PermissionSetLicenseAssign> pslAssignments = new List<PermissionSetLicenseAssign>();
                for (Id pslId : targetPslIds) {
                    pslAssignments.add(new PermissionSetLicenseAssign(
                        AssigneeId = u.Id,
                        PermissionSetLicenseId = pslId
                    ));
                }
                insert pslAssignments;
            }
        }

        assignPermissionSetsToUser(u.Id, PERM_SETS);
    }

    /* =====================================================
       5. LICENSE FETCH
       ===================================================== */
    @TestVisible
    private static Set<Id> getPermissionSetLicenseIds() {
        if (Test.isRunningTest()) {
            return new Set<Id>();
        }

        return new Map<Id, PermissionSetLicense>([
            SELECT Id
            FROM PermissionSetLicense
            WHERE DeveloperName IN :PERM_SET_LICENSES
        ]).keySet();
    }

    /* =====================================================
       6. HELPER - ASSIGN PERMISSION SETS
       ===================================================== */
    @TestVisible
    private static void assignPermissionSetsToUser(Id userId, Set<String> permissionSetNames) {
        if (userId == null || permissionSetNames == null || permissionSetNames.isEmpty()) {
            return;
        }

        Set<Id> targetPsIds = new Map<Id, PermissionSet>([
            SELECT Id
            FROM PermissionSet
            WHERE Name IN :permissionSetNames
        ]).keySet();

        if (targetPsIds.isEmpty()) {
            return;
        }

        Set<Id> alreadyAssignedPsIds = new Set<Id>();
        for (PermissionSetAssignment psa : [
            SELECT PermissionSetId
            FROM PermissionSetAssignment
            WHERE AssigneeId = :userId
              AND PermissionSetId IN :targetPsIds
        ]) {
            alreadyAssignedPsIds.add(psa.PermissionSetId);
        }

        targetPsIds.removeAll(alreadyAssignedPsIds);

        if (!targetPsIds.isEmpty()) {
            List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
            for (Id psId : targetPsIds) {
                assignments.add(new PermissionSetAssignment(
                    AssigneeId = userId,
                    PermissionSetId = psId
                ));
            }
            insert assignments;
        }
    }
   
    public static void createCareCordinatorUser(){
        UserRole rep = [SELECT Id FROM UserRole WHERE DeveloperName = 'Care_Coordinator' LIMIT 1];
        Profile prof= [SELECT Id FROM Profile WHERE Name = 'Care Coordinator' LIMIT 1];

        String unique = String.valueOf(DateTime.now().getTime());
        String aliasSuffix = unique.length() >= 3
            ? unique.substring(unique.length() - 3)
            : unique;
        // Create User
        User usr = new User(
            LastName = 'Care Coordinator',
            FirstName = 'Clinical',
            Email = 'cccare' + unique + '@test.com',
            Username = 'cccare' + unique + '@test.com',
            Alias = ('cr' + aliasSuffix).left(8),
            ProfileId = prof.Id,
            UserRoleId = rep.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        
        insert usr;
    }

    public static void contactUpdationIntoAsset(){
        List<Contact> contactList = [Select id,name,AccountId from Contact where isHealthCloudRecord__c =: true
                                     AND AccountId != null];
        
        
        Map<Id, Id> accountToContactMap = new Map<Id, Id>();
        for (Contact c : contactList) {
            // If multiple contacts per account, first one wins
            if (!accountToContactMap.containsKey(c.AccountId)) {
                accountToContactMap.put(c.AccountId, c.Id);
            }
        }
        
        system.debug('Contact Id value:'+accountToContactMap);
        
        List<Asset> assetList = [Select id,name,AccountId,ContactId from Asset where AccountId IN :accountToContactMap.keySet()];
        system.debug('Asset List:'+assetList);
        List<Asset> assetsToUpdate = new List<Asset>();
        
        for(Asset a:assetList){
            
            Id contactId = accountToContactMap.get(a.AccountId);
            
            if (contactId != null && a.ContactId != contactId) {
                a.ContactId = contactId;
                assetsToUpdate.add(a);
            } 
        }
        
        if (!assetsToUpdate.isEmpty()) {
            update assetsToUpdate;
        }
        system.debug('assetsToUpdate:'+assetsToUpdate);   
    }

}
