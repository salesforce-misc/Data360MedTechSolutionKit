/**
 * Helper class to assign app visibility to System Administrator profile
 *
 * IMPORTANT: This class uses Metadata API via Tooling API to add profiles to apps.
 * The current user must have "Modify All Data" or "Customize Application" permission.
 *
 * Usage: AppProfileAssignmentHelper.assignAppToCurrentUser('Pulse Sync App');
 */
public with sharing class AppProfileAssignmentHelper {

    /**
     * Assign app to System Administrator profile so it appears in "Selected Profiles"
     * This uses a workaround since we cannot directly modify Profile metadata via Apex.
     *
     * The solution: Use Permission Sets which functionally grants the same access.
     *
     * NOTE: Due to Salesforce limitations, this WILL NOT show the profile in the
     * "Selected Profiles" list in App Manager UI. However, users with the Permission
     * Set WILL have access to the app.
     *
     * To add profiles to "Selected Profiles" in UI, you must either:
     * 1. Use browser automation to click through App Manager UI
     * 2. Deploy Profile metadata XML with applicationVisibilities section
     * 3. Manually select profiles in Setup → App Manager
     *
     * @param appLabel - The label of the Lightning App (e.g., 'Pulse Sync App')
     * @return Map<String, String> - Result details
     */
    public static Map<String, String> assignAppToCurrentUser(String appLabel) {
        Map<String, String> result = new Map<String, String>();

        try {
            System.debug('⚠️  LIMITATION: This method grants app access via Permission Set.');
            System.debug('⚠️  The profile will NOT appear in App Settings → User Profiles → Selected Profiles.');
            System.debug('⚠️  To add profiles to that list, you must use UI automation or deploy Profile metadata.');

            // Get app ID
            String appId = getAppId(appLabel);
            result.put('appId', appId);

            // Get current user profile
            String profileName = UserInfo.getProfileId();
            User currentUser = [SELECT Profile.Name FROM User WHERE Id = :UserInfo.getUserId()];
            result.put('profileName', currentUser.Profile.Name);

            System.debug('Current Profile: ' + currentUser.Profile.Name);
            System.debug('❌ CANNOT add profile to app via Apex - Salesforce limitation');
            System.debug('');
            System.debug('✅ WORKAROUND: Creating Permission Set to grant access instead');

            // Workaround: Use Permission Set
            String permissionSetId = getOrCreatePermissionSet();
            grantAppAccessToPermissionSet(permissionSetId, appId);
            assignPermissionSetToCurrentUser(permissionSetId);

            result.put('permissionSetId', permissionSetId);
            result.put('status', 'SUCCESS_WITH_WORKAROUND');
            result.put('message', 'App access granted via Permission Set. Profile will not show in App Manager Selected Profiles list.');

        } catch (Exception e) {
            result.put('status', 'ERROR');
            result.put('error', e.getMessage());
            System.debug('❌ Error: ' + e.getMessage());
        }

        return result;
    }

    private static String getAppId(String appLabel) {
        List<AppMenuItem> appMenuItems = [
            SELECT ApplicationId, Label
            FROM AppMenuItem
            WHERE Label = :appLabel
            LIMIT 1
        ];

        if (appMenuItems.isEmpty()) {
            throw new AppProfileException('App not found: ' + appLabel);
        }

        return appMenuItems[0].ApplicationId;
    }

    private static String getOrCreatePermissionSet() {
        String permSetName = 'Pulse_Sync_App_Access';

        List<PermissionSet> existingPS = [
            SELECT Id FROM PermissionSet WHERE Name = :permSetName LIMIT 1
        ];

        if (!existingPS.isEmpty()) {
            return existingPS[0].Id;
        }

        PermissionSet ps = new PermissionSet(
            Name = permSetName,
            Label = 'Pulse Sync App Access'
        );
        insert ps;
        return ps.Id;
    }

    private static void grantAppAccessToPermissionSet(String permissionSetId, String appId) {
        List<SetupEntityAccess> existing = [
            SELECT Id FROM SetupEntityAccess
            WHERE ParentId = :permissionSetId AND SetupEntityId = :appId
        ];

        if (!existing.isEmpty()) {
            return;
        }

        insert new SetupEntityAccess(
            ParentId = permissionSetId,
            SetupEntityId = appId
        );
    }

    private static void assignPermissionSetToCurrentUser(String permissionSetId) {
        Id userId = UserInfo.getUserId();

        List<PermissionSetAssignment> existing = [
            SELECT Id FROM PermissionSetAssignment
            WHERE PermissionSetId = :permissionSetId AND AssigneeId = :userId
        ];

        if (!existing.isEmpty()) {
            return;
        }

        insert new PermissionSetAssignment(
            PermissionSetId = permissionSetId,
            AssigneeId = userId
        );

        User u = [SELECT Username FROM User WHERE Id = :userId];
        System.debug('✅ Granted app access to: ' + u.Username);
    }

    public class AppProfileException extends Exception {}
}