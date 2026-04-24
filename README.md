# Data360MedTechSolutionKit
<details><summary>

  ## 1. Pre-Deployment Instructions
</summary>


### Step 1. Salesforce Org Setup Requirements for the PulseSync App (5 min)

   To support the PulseSync app, you can either create a new Salesforce Org or use an existing one, provided it includes the following features and licenses: 

  | Requirement | Details |
  | ----- | ----- |
  | Licenses Required | - Data Cloud</br>- Sales Cloud</br>- Service Cloud</br>- Health Cloud</br>- Health Cloud Platform|
  | Features Required | - Service Agent</br>- Einstein Agent</br>- Copilot</br>- Prompt Builder</br>- Agentforce Data Library</br> - Agentforce Studio</br> - Process Content - DocumentAI</br> - NotebookAI|


> [!IMPORTANT]
> It is recommended to start with a brand-new environment to avoid conflicts with any previous work you may have done. A developer org can also be used.

### Step 2. Salesforce CLI
- Install VSCode [Download](https://code.visualstudio.com/download)
- [Install the Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) or Verify that your installed CLI version is greater than `2.56.7` by running `sf -v` in a terminal.
- Open VS Code >Go To >Extensions >Search for Salesforce Extension Pack >Click Install
- Install Git(Ignore if already installed) [Git](https://git-scm.com/install/)
- Open VS Code >Go To Extensions >Search for Git Extension Pack >Click Install
### Step 3. Enable Data Cloud.

| Step | Action and Details | Images |
| ----- | ----- | ----- |
| Verify and Enable Data Cloud for Your Org |- Ensure that Data Cloud provisioning is complete before proceeding..</br>- To verify this, navigate to Data Cloud Setup. If provisioning is complete, the page will appear as shown.</br>- If you see a **Get Started** button, click it and wait for the process to finish.</br>- This process can take up to ten minutes.|<img width="450" alt="DatacloudSetup" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Pre-Deployment/DataCloudSetupHome.png">|

### Step 4. Enable Features In Your Environment (20 minutes)

| Step | Action and Details | Images |
| ----- | ----- | ----- |
| Turn on Einstein |- Go to Setup.</br>- In the Quick Find box, search for Einstein Setup.</br>- Click **Turn On Einstein**.|<img width="450" alt="Einstein" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Pre-Deployment/Turn%20on%20Einstein.png?raw=true">|
| Turn on Agentforce |**Note:** You may need to refresh the page to see the Agentforce Agents menu after turning on Einstein.<br><br>- Go to Setup.</br>- In the Quick Find box, type **Agentforce Agents**.</br>- Toggle on **Agentforce**.|<img width="450" alt="Agent1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Pre-Deployment/AgentforceAgents02.png">|
| Modify the Data Cloud Architect Permission Set | - Go to Setup.</br>- In the Quick Find box, search for and select **Permission Sets**.</br>- Open the **Data Cloud Architect** permission set.</br>- Click **Data Cloud Data Space Management** under Apps.</br>- Click Edit, **Enable the default data space**, and click Save.</br>- Confirm by clicking OK.|<img width="450" alt="DSSpace2" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Pre-Deployment/DC%20Architect%20Data%20Space%20Enable.png">|
| Assign Health Cloud Permission Set Licenses to Logged-in User |- Click on your **Avatar (Profile Icon)** in the top-right corner.</br> - Select **Settings** (or **My Settings**).</br> - In the left panel, navigate to **Advanced User Details** or **Personal Information**.</br> - Click **View** next to your user details.</br> - Scroll down to **Permission Set License Assignments** section.</br> - Click **Edit Assignments**.</br> - Search for **Health Cloud**, **Health Cloud Platform** licenses and Enable.</br>- Click **Save**.||
| Enable Person Account |- Go to Setup.</br>- Enter Person Accounts in the Quick Find box and select **Person Accounts**.</br>- Review the information and steps provided on the Setup page to understand the configuration.</br>- Turn on the Person Accounts Toggle."|<img width="450" alt="PS" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Pre-Deployment/PersonAccounts.png">|
| Enable Notebook AI | - Go to Setup. <br>- Search for Feature Manager and  scroll down.<br>- Enable Notebook AI.|<img width="450" alt="DSSpace4" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/FeatureManager(Notebook%20AI).png">|

### Step 5. Base metadata deployment

1. Clone this repository:

    ```bash
    git clone https://git.soma.salesforce.com/gdevadoss/Data360MedTechSolutionKit.git
    ```

1. Authorize your org with the Salesforce CLI.

   Ctrl+Shift+P Select SFDX:Authorize an Org -> Select Project Default -> Enter the Org alias -> Authorize the Org.

1. Assign below Health Cloud Permission Sets to the Default User.

   ```bash
   sf org assign permset -n HealthCloudFoundation
   sf org assign permset -n HealthCloudUtilizationManagement
   sf org assign permset -n DiseaseSurveillance
    ```

1. Deploy the base app metadata.

    ```bash
    sf project deploy start -d ps-base
    ```
 
1. Assign Base Permission Set to Default User.

   ```bash
   sf org assign permset -n PulseSyncBasePS
    ```
1. Activate Standard PriceBook.

    ```bash
    sf apex run -f scripts/apex/activatePricebook.apex
    ```
1. Replace the Standard Price Book variable in the JSON file with the actual Standard PricebookId by following the steps below in order.
   ***Choose PowerShell in VS code Terminal**


    ```bash
    $pbQuery = sf data query -q "SELECT Id FROM Pricebook2 WHERE IsStandard = true AND IsActive = true LIMIT 1" --json | ConvertFrom-Json
    ```
    ```bash
    $STD_PB_ID = $pbQuery.result.records[0].Id
    ```
    ```bash
    Write-Output "Standard Price Book Id: $STD_PB_ID"
    ```
    ```bash
    (Get-Content data\pricebookentries.json) -replace "STANDARD_PRICEBOOK_ID", $STD_PB_ID | Set-Content data\pricebookentries.json
    ```

1. Import Sample data.

    ```bash
    sf data tree import -p data/plan.json
   ```
1. Enable Data Cloud Copy Field Permissions.

    ```bash
    sf apex run -f scripts/apex/assignCopyFieldPermissions.apex
    ```
</details>

<details><summary>
  
## 2. Data Cloud Configuration
</summary>

### Step 1. Install Datakit and Deploy In Your Environment.

| Step | Action and Details | Image |
|------|-------------|-------|
| Install Data Kit | - **Install Data Kit**:<br>`sf project deploy start -d ps-datacloud`<br><br>- **Open your org** (if not already open):<br>`sf org open` | ![](images/datakit.png) |
| Deploy Datakit Into Your Org | - Go to **Setup**. </br>- Enter **Data Kits** in the **Quick Find** box. </br>- Select **Data360MedTechSolutionKit**. <br>- Click **Datakit Deploy**. <br><br>**Note**: The deployment process may take approximately 25 minutes to complete. You can monitor the progress in the Deployment History section.|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DataKit.png)|

### Step 2. Extract Source files.

| Step | Action and Details | Image |
|------|--------------------|-------|
| Navigate to Documents folder in GitHub Repository | - Open a web browser and go to [GitHub](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/MedTechDocuments).<br>- Once inside the repository, you will see the **MedTech Documents** at the root level.<br>- Click on **Pre_Implant_Report** to open the file.<br>- Click on **Download** to save in your system.<br>**Note**: Follow the above procedure to download the following documents: **Implant_Report**, **Call_Transcript**, **Post_Implant_Report**, **ClinicianNote_DischargeSummary**, **Initial_Interrogation**, **Last_Interrogation**,**Pacemaker Patient Guide**,**Mark_Smith_OP_Note**.Ensure that all files are securely saved to your local system, as they will be required for subsequent processing and configuration steps.| |

### Step 3. Setup Notebook AI Workspace 
| Step | Action and Details | Image |
|------|--------------------|-------|
| Notebook AI Workspace Setup |<br>- Go to App Manager Search for Notebook AI.<br>- Click on New Notebook. <br>- Provide notebook name as **Diagnosis**. <br>- Under Personal Library, click on the (+) icon. <br>- Upload the following documents: <br>&nbsp;&nbsp;&nbsp;&nbsp;(a) Pre_Implant_Report<br>&nbsp;&nbsp;&nbsp;&nbsp;(b) Implant_Report<br>&nbsp;&nbsp;&nbsp;&nbsp;(c) Call_Transcript<br>&nbsp;&nbsp;&nbsp;&nbsp;(d) Post_Implant_Report<br>&nbsp;&nbsp;&nbsp;&nbsp;(e) ClinicianNote_DischargeSummary<br>&nbsp;&nbsp;&nbsp;&nbsp;(f) Initial_Interrogation<br>&nbsp;&nbsp;&nbsp;&nbsp;(g) Last_Interrogation|<img width="350" alt="Notebook AI" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/Notebook%20AI%20New.png"><img width="350" alt="Notebook AI Upload" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/Notebook%20AI%20upload.png"><img width="350" alt="Notebook AI Docs" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/Notebook%20AI%20document.png">|

### Step 4. Agentforce Data Library Setup

| Step | Action and Details | Image |
|------|--------------------|-------|
| Agentforce Data Library Setup and Files Upload | - Go to **Setup** .<br>- In QuickFind box Search and Select **Agentforce Data Library**.<br>- Click **New Library**. <br>- Enter the name **Pacemaker Implant Guide** <br>- Click **Save**.<br><br>-Under the Pacemaker Implant Guide library, set Data Type to Files → Click Upload Files.<br>- Choose the **Pacemaker Patient Guide.pdf**file (downloaded in the previous step) → Once the upload is complete, click Done. <br><br>-You can wait until the **Status** updates to **Ready** .This  process may take approximately 20 minutes.<br> Follow the steps described above to create the additional libraries: <br/>i.  Create a library named **Patient Clinician Discharge And Interrogation Note**, set the Data Type to **Files** and upload the **ClinicianNote_DischargeSummary.pdf** file that was downloaded in the previous step.<br/>ii. Create a library named **Patient OP**,set the Data Type to **Files** and upload the **Mark_Smith_OP_Note.pdf** file that was downloaded in the previous step. |<img width="350" alt="Notebook AI" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/AgentforceDataLibraryNew.png"><img width="350" alt="Notebook AI" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DataLibraryFileType.png"><img width="350" alt="Notebook AI" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DataLibraryFileUpload.png">|

### Step 5. Setup Document AI.

| Step | Action and Details | Image |
|------|--------------------|-------|
| Create Document AI |- Open Data Cloud App from App launcher.<br/>- Search for and Select Process Content. <br>- Click on Document AI.<br/>- Click on New button>>Select From a Source Object option>>Click Next.<br/>- Select an Unstructured Data Model Object as **ADL_Patient_Op__dlm**. <br/>- Click on Next button.<br>- Enable toggle for  **PDF** under Select File Types and click Next.<br/>- Select **OpenAI GPT-4o** option under Select a Large Language Model and click Next.<br/>- Click **Add** and select New.<br>- Enter Data Lake Object Name as **DAI Patient OP** and API Name auto populate.<br/>- Click on Next.<br/>- Upload the file as **Mark_Smith_OP_Note.PDF** and select **Using Auto-Extraction** option and click Next.<br/>- Once field extracted then create the remaining field by  referring the screenshot.<br/>- Click Add Field button enter Name and select field type as String and again click Add.<br/>- Click on Save and click on next. <br/>- Enter Document Schema Name as **DIA Patient OP Schema** and click on Save.|<img width="300" alt="docAi1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DocumentAI1.png"> <img width="300" alt="docAi2" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DocumentAI2.png"> <img width="300" alt="docAi3" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DocumentAI3.png"> <img width="300" alt="docAi4" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DocumentAI4.png"> <img width="300" alt="docAi5" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DocumentAIFields1.png"> <img width="300" alt="docAi6" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DocumentAIFields2.png"> <img width="300" alt="docAi7" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DocumentAIFields3.png"> <img width="300" alt="docAi7" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DocumentAISchemaName.png">|
| Create Search Index for Document AI |- Open Data Cloud App from App launcher.<br/>- Search for and Select Search Index>>Click New <br>-Select Easy Setup and click Next<br/>-Select DAI Patient OP DMO and click Next<br/>-Click Save|<img width="300" alt="docAi8" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DocumentAiSi1.png"> <img width="300" alt="docAi9" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DocumentAiSi2.png">|
| Create Retriever for Document AI |- Open Data Cloud App from App launcher.<br/>- Search for and Select Einstein Studio >>Select Retrievers >>Click New Retriever<br/>-Select Individual Retriever and click Next<br/>-Click Data Cloud and Select default value for In which data space does the source data reside? , Select DAI Patient Op as Select a data model object,Select DAI Patient OP Search Index >>Click Next<br/>-Select All Documents and click Next<br/>-Click Field Name >> Select Direct Attribute >> Select DIA Patient OP >> Select atrialLeadModel <br/>- Click Add Field >> Add the fields by referring screnshot<br/>-Click Save <br/> Click Activate|<img width="300" alt="docAire1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DoucmentAiRet1.png"> <img width="300" alt="docAire2" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DoucmentAiRet2.png"> <img width="300" alt="docAire3" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DoucmentAiRet3.png">|

### Step 6. Upload Files for Datastreams.

| Step | Action and Details | Image |
|------|--------------------|-------|
| Update File in Data Cloud |- Navigate to **Data Cloud** from the **App Launcher** <br>- Go to **Data Streams** (sometimes under **Data → Data Streams**). <br>- Click on **pacemaker_iot_data** where the **Connection Type** is set to **File Upload**.<br>- Click **Update File** in the Data Stream interface to open the file selection dialog.<br>- Upload the new file:<br>- Browse and select the **pacemaker_iot_data** filethat was downloaded in the previous step.<br>- Ensure the file matches the expected format (CSV, JSON, etc.).<br>- Click **Deploy**.<br>- Verify the file in the Data Stream:<br>- Optionally, check **Processing History** or **Deployment History** to ensure the file was ingested successfully without errors.|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DataStream%20Via%20File.png)![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/UploadFileForDS.png)|
| Data Cloud Copy Field Enrichment Sync | - Go to Object Manager.</br>- Search for and select Contact.</br>- Click on Data Cloud Copy Field.</br>- Select **Pacemaker Patient Health Summary default**<br>- Click Start Sync**.</br>- In the dialog box, click Start Sync.</br>- This process can take up to 15 minutes to complete.</br>- Click Sync History to ensure the status is Complete.</br>**Note:** Ensure that the sync status for each field is verified and confirmed.|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/CopyFieldOnContact.png)![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/CopyFieldVariable.png)![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/CopyFieldStartSync.png) |
| Data Cloud Related List to the Contact | - Go to Object Manager.</br>- Search for and select Contact.</br>- Go to the Data Cloud Related List tab.</br>- Click New.</br>- Under Data Cloud Object, select **pacemaker_iot_data** and click Next.</br>- Keep the default values and click Next.</br>- Change the related list label to **Pacemaker IOT**.</br>- Check the Contact Layout checkbox.</br>- Check the Add related list to users’ existing record page customizations checkbox.</br>- Click Next.</br> |![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DCRelatedListNew.png)![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DCRelatedListUnified.png)![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DCRelatedListLayout.png)|


### Step 7. Refresh Data Cloud Components


| Step | Action and Details | Images |
| ----- | ----- | ----- |
| Refresh Data Stream | - Go to App Launcher</br>- Click on the Data Cloud App</br>- Navigate to the Data Streams tab</br>- For each data stream listed, click the downward arrow on the right-hand side of the data stream name and select Refresh Now</br>- Wait until the status shows Success and verify the Last Processed Records</br>- Follow above steps one by one for all Data Streams: **Account_Home**, **Contact_Home**,**Case_Home**, **Product2_Home**, **Pricebook2_Home**, **PricebookEntry_Home**, **Asset_Home**, **Task_Home**, **Entitlement_Home**, **ServiceAppointment_Home**, **AllergyIntolerance_Home**, **CodeSet_Home**, **CodeSetBundle_Home**, **Medication_Home**, **PatientMedicalProcedure_Home**, **HealthCondition_Home**,**MedicationRequest_Home**|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DataStream.png)|
| Run Identity Resolution Ruleset | - Go to the **Identity Resolution** tab</br>- Choose and select **Unify Patient IOT Data**</br>- Click **Run Ruleset** |![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/IdentityResolution.png) |
| Run Calculated Insights | - Go to the **Calculated Insights** tab</br>- Choose and select **Pacemaker Latest Transmission**<br>- Click **Publish Now** <br>- Follow the above steps to the following calculated insight :<br/>- **Pacemaker Patient Health Summary** </br>- Click Run Publish Now|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/CalculatedInsight.png)| 
| Publish Segment |- Go to the Segment tab.</br>- Choose and select **Anomalous Pacemaker Battery**. </br>- Click Run Publish Now|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/Segment.png)| 

⚠️ **Important Note:** If you still cannot see the values under Account 360 Record page then follow the above refresh steps again in the same series. 


</details>

<details><summary>

  ## 3. Agentforce Agents Installation
</summary>

### Step 1. Install Agents and Activate

| Step | Action and Details | Image |
|------|-------------|-------|
| Agent Setup and Configuration | - **Install Agents**:<br>`sf project deploy start -d ps-post-pack`<br><br>- **Assign Permission Set to the Default User**:<br>`sf org assign permset -n PulseSyncCustomPS`.<br></br>- **Activate Agent**: <br>`sf agent activate --api-name Clinician_Copilot`<br><br>- **Create Agent User**:<br>`sf apex run -f scripts/apex/createAgentUser.apex`<br></br>- **Open your org**(if not already open):</br>`sf org open`.
| Assign User to Service Agent |- Click on Setup <br>-Search for and Select Agentforce Agents.<br>- Click on **PulseSync Assistant** <br>- Click on Open Builder <br/>- Click on setting->Click on company field and just give one space and remove space.<br/>- Select Agent User to Service Agent User.<br>- Click on Activate|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/AgentUserPermission.png)|
| Add Pacemaker Implant Guide Retriever |- Go to **Setup** → enter **Prompt Builder** → open **Monitor Troubleshoot Support** prompt template</br>- Replace **ADL_PACEMAKER_IMPLANT** with a retriever:</br>&nbsp;&nbsp;i. Click **Insert Resource** → **Retrievers** → **Configure Retrievers**</br>&nbsp;&nbsp;ii. Select the retriever created by the ADL when you **uploaded the file for Pacemaker Implant Guide(Eg:File_ADL_JYHi_Pacemaker )** </br>&nbsp;&nbsp;iii. Under **Search Text**, choose **Free Text** → **Question**</br>&nbsp;&nbsp;iv. For **Output Fields**, select **Chunk** → **Apply and Insert**</br>&nbsp;&nbsp;v. Click **Save As** → **Save as New Version** → **Activate**.<br><br>**Note** Follow the above step for adding Retriever to the below Prompt Templates: **Post Implant Care**,**PacemakerDetailsForGuest**,**DeviceRegulatoryInfo**,**HomeMonitorSetupGuide** and **WarrantyDurationDetails**.|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/PacemakerDetailRetriever.png)![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/NewRetriever.png)![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/RetrieverConfiguration.png)|
| Add Patient Implant Op Retriever |- Go to **Setup** → enter **Prompt Builder** → open **Patient Implant Op Prompt** prompt template.</br>- Replace **DAI_SI_Patient_OP_Retriever** with a retriever:</br>&nbsp;&nbsp;i. Click **Insert Resource** → **Retrievers** → **Configure Retrievers**</br>&nbsp;&nbsp;ii. Select the retriever created manually for Document AI **(Eg:DAI SI Patient OP Retriever)** </br>&nbsp;&nbsp;;iii. Under **Search Text**, choose **Free Text** → **Id** and **Question**.</br>&nbsp;&nbsp;iv. For **Output Fields**, select **deviceModel**, **deviceSerial**,**implantSite** and **patientName** → **Apply and Insert**</br>&nbsp;&nbsp;v. Click **Save As** → **Save as New Version** → **Activate**.|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/PatientImplantOP.png)|
| Add Patient Summary Retriever | - Go to **Setup** → Enter **Prompt Builder** → open **Patient30DaysSummary** prompt template<br>- Click on the Apex class and verify if the Input:Id has been assigned to Account Input.</br>- Replace **DAI_PATIENT_OP** with a retriever:</br>&nbsp;&nbsp;i. Click **Insert Resource** → **Retrievers** → **Configure Retrievers**</br>&nbsp;&nbsp;ii. Select the retriever created by the ADL when you **uploaded the file for Patient OP(Eg:File_ADL_Patient_OP)** </br>&nbsp;&nbsp;iii. Under **Search Text**, choose **Free Text** → **Id**.<br><br>- Replace **Patient_Clinician_Retriever** with a retriever:</br>&nbsp;&nbsp;i. Click **Insert Resource** → **Retrievers** → **Configure Retrievers**</br>&nbsp;&nbsp;ii. Select the retriever created by the ADL when you **uploaded the file for Patient_Clinician_Notes(Eg:File_ADL_Patient_Clinici)** </br>&nbsp;&nbsp;iii. Under **Search Text**, choose **Free Text** → **Question**→ **Apply and Insert**</br>&nbsp;&nbsp;iv. Click **Save As** → **Save as New Version** → **Activate**|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/PatientSummary1.png)![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/PatientSummary2.png)|
| Assigning Permission to App | - Go to Setup <br>- Search for **App Manager**<br>- Click on **Pulse Sync App**<br>- Click on **Edit** from arrow.<br>- Click **User Profiles**<br>- Search **System Administrator** from Available Profiles and select it and click on right arrow -> so it will be present under **Selected Profiles** <br>- Click on Save|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/PulsesyncApp.png)![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/PulseSyncSystemadmin.png)|
| Activate Account Record Page | - Go to Setup. <br>- In Quick Find, Search and Select **Lightning App Builder**.<br>- Click on **Patient Account Page** from the list.<br>- Click on **Edit**. <br>- In the top-right corner, click **Activate**. <br>- Click on **Assign as Org Default** in the popup <br>- Click **Save**|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/PulsesyncRecordPage.png)![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/PulsesyncOrgDefault.png)|


</details>

<details><summary>

 ## 4. (Optional) Deploy Service Agent on an External Website
</summary>

### Step 1. Embedded Service Messaging Setup and Configuration

| Step | Action and Details | Image |
|------|-------------|-------|
| Enable Messaging Channel | - Navigate to Setup >> Search for and Select **Messaging Setting**. </br>- Toggle on **Messaging**.|<img width="300" alt="MSEnable" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentExternalWebsite/MessagingSettingEnable.png">|
| Embedded Service Package Installation|- **Install Embedded Service Package**:</br>`sf project deploy start -d ps-embeddedservice`.
| Configure Site Setting |- In Setup, search for and select **Sites** and click **Register My Salesforce Site Domain**.</br>- After registration, open the Embedded Service Deployment and locate the Site Endpoint that starts with **ESW** (ESA Web Deployment).</br>- Click the endpoint link to open the site settings.</br>- Under Trusted Domains for Inline Frames, click **Add Domain**.</br>- Enter the same external website URL used earlier.</br>- Click Save.|<img width="300" alt="RegisterDomain" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentExternalWebsite/RegisterDomain.png"> <img width="300" alt="RegisterDomain1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentExternalWebsite/RegisterDomain1.png">|
| Activate Messaging Channel |- **Activate Messaging Channel**:</br>`sf apex run -f scripts/apex/activateMessagingChannel.apex`
| Publish ESA | - Click on Setup. </br>- In Quick Find, Search and Select Embedded Service Deployments.</br>- Click on **ESA Web Deployment**. </br>- Click on 'Publish' button. </br>- Hold for confirmation Message. |<img width="300" alt="ESApublish" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentExternalWebsite/ESAPublish.png">|
| Create a New Version of Omni-Channel Flow  |- Click on Setup.</br>- Search for Flows in the Quick Find box and select it.</br>- Open the flow **Route Conversations to Agentforce Service Agents**.</br>- Deactivate the flow and open the**Route to Service Agent** element.</br>- Refresh the Service Channel by selecting a different option and then reselect **Live Messaging**.</br>- Set Route To as **Agentforce Service Agent** and choose **PulseSync Assistant**.</br>- In Fallback Queue ID, remove the existing queue and reselect the same queue.</br>- Click Save As New Version, then click **Activate**.  |<img width="300" alt="RouteEsa" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentExternalWebsite/Routetoesaflow.png">|

### Step 2. CORS Configuration

| Step | Action and Details | Image |
|------|-------------|-------|
| Configure CORS Settings | - From Setup, search for and select  **CORS** >> click New.</br>- Enter the **external website URL. Do not include a trailing “/”**.</br>- Click **New** and Add.<br>   _https://*.my.salesforce-scrt.com_|<img width="300" alt="CorsExt" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentExternalWebsite/corsexternalsite.png">|


### Step 3. Trusted URL Configuration

| Step | Action and Details | Image |
|------|-------------|-------|
| Configure Trusted URL | - In Setup, search for **Trusted URLs** and select it, then click **New Trusted Domain**.</br>- Enter the **API Name and URL — use the same external site URL provided earlier**.</br>- Select **frame-src (iframe content)**.</br>- Click Save.||


### Step 4. Get Embedded Service Deployment Code Snippet

| Step | Action and Details | Image |
|------|-------------|-------|
| Script for Executing Agent in External Site |- From Setup, search for Embedded Service Deployments.</br>- Select ESA Web Deployment, scroll down, and click **Install Code Snippet**.</br>- **Copy the code snippet**. |<img width="300" alt="Codesnippet" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentExternalWebsite/codesnippet.png">|


### Step 5. Verify the Agent on the External Website

  That’s it! You’re all set. The Agentforce widget should now be visible on your external website.
</details>

<details><summary>

 ## 5. (Optional) Setup Commerce Cloud and Experience Cloud
</summary>


### Step 1. Experience Cloud Setup

  | Step | Action and Details | Images |
  | ----- | ----- | ----- |
   | Enable Commerce Cloud | - From Setup, enter **Commerce** in the Quick Find box.</br>- Select **Settings** under **Commerce**.</br>- Turn on **Enable Commerce**. |<img width="300" alt="CommerceEnable" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/CommerceEnable.png">|
   | Create a Experience Site | - From Setup, enter **Digital Experiences** in the Quick Find box -> Select **All Sites** under **Digital Experiences**.</br>- Click New to open the Creation wizard with template options and Select the **Commerce Store (LWR)** template.</br>- Click Get Started.</br>- Provide Store Name as ‘PulseSync’ and ensure the URL ends with /PulseSync</br>- Click Create. Your site will be created in Preview status. | <img width="300" alt="CommerceLwrTemplate" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/CommerceLwrTemplate.png"> <img width="300" alt="CommerceLwrTemplate" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/CommerceLwrTemplate1.png">|
   | Activate Site | - From Setup, enter **Digital Experiences** and select **All Sites** under **Digital Experiences**.</br>- Click Workspaces next to **PluseSync**.</br>- Select Administration.</br>- In Settings, click Activate and confirm by clicking OK.</br>- Your site will now be live and fully set up.|<img width="300" alt="ExpSiteActive" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/ExpSiteActive.png?raw=true">|
   | Register Site Setting |- Go to Domains from Setup under User Interface and copy the Experience Cloud Sites Domain.</br>- Search for and Select **Sites** from User Interface >>Click on the **Site Label** for **ESW Web Deployment site**.</br>- Under Trusted Domains for Inline Frames, click New.</br>- Paste the copied domain URL and click Save. |<img width="300" alt="registersite" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/registersitedomain.png"> <img width="300" alt="registersite1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/RegisterDomain1.png"> |
   | Digital Experience  |- From Setup, search for Digital Experiences and click on Settings under Digital Experiences.</br>- Select the **Allow using standard external profiles for self-registration, user creation, and login** checkbox </br>- Click Save and click OK in the dialog box.|<img width="300" alt="SiteSetting" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/SiteSettings.png">|
   | Experience Cloud Automated Setup | - **Deploy Experience cloud package**</br>`sf project deploy start -d ps-pd-experience-optional`<br></br>- **Create Experience Site User**<br>`sf apex run -f scripts/apex/createSiteUser.apex` ||
   | CORS Configuration | - From Setup, search for CORS and click New.</br>- Add **https://*.my.salesforce-scrt.com** and Save.</br>- From Setup, search for and select **Domains** under **User Interface**.</br>- Copy the **My Domain URL** and the **Experience Cloud Sites Domain**.</br>- Add both URLs separately in CORS, **ensure it starts with https://** and click Save.|<img width="300" alt="Cors1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/Cors1.png">|
  |Trusted URL | - Go to **Domains** under **User Interface** and copy the Experience Cloud Sites Domain.</br>- From Setup, search for Trusted URLs and click New Trusted URL.</br>- Enter the Name as **PulseSync** and paste the copied domain URL, ensuring it starts with https://.</br>- Make Sure to select all the CSP directives. </br>- Click Save. |<img width="300" alt="TrustedUrl1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/TrustedUrl.png">|
|Update CPS Trusted URL | - Go to **Domains** under **User Interface** and copy the Experience Cloud Sites Domain url.</br>- From Setup, search for and Select All Sites and Click Builder next to **PluseSync**. </br>- Click Setting and click **Security & Privacy** <br/>- Scroll down to Trusted Sites for Scripts section and edit the **Site Url** and paste the Experience Cloud Sites Domain URL and click on Update. <br/>- Publish the Site |<img width="300" alt="CSP" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/UpdateCSPURL.png">|
### Step 2. Commerce Cloud Setup
  | Step | Action and Details | Images |
  | ----- | ----- | ----- |
  | Enable Search Index | - Click on App Launcher, Search and Select Commerce application.</br>- Scroll down to Setting and expand it</br>- Click on Search</br>- Use the toggle to turn on Automatic Updates.|<img width="300" alt="Si" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/CommerceSI.png">|
  | Enable Guest access | - Click on the App Launcher, search for and select the Commerce application and select **PulseSync**. </br>- On the left-hand side, click Stores under Settings. </br>- Navigate to the Buyer Access tab. </br>- Scroll down to the Guest Access section. </br>- Click on **Enable button** and click on Continue.|<img width="300" alt="GuestAccess" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/GuestAccessEnable.png">|
  | Assign Guest User to Buyer Group | - In the **PulseSync** store,  On the left-hand side, click Stores under Settings >> Click on Buyer Access Tab </br>- Click on **PulseSync Guest Buyer Profile** under Guest Access .</br>- Click on Related ->Click on Buyer Groups , Click on Assign Button <br/> -Select the checkbox for **PulseSync Buyer Group** and click on Assign Button|<img width="300" alt="GuestBuyerGrp" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/GuestBuyerGrpMember.png">|
  | Assign Customer User to Buyer Group |- Go to the App Launcher, search for Accounts, and open it.</br>- Open the **Mark Smith** account and click **Enable as Buyer**.</br>- In **PulseSync** commerce store, navigate to Settings > Buyer Access.</br>- Open the **PulseSync Buyer Group**.</br>- Under Buyer Group Members, click Assign, search for **Mark Smith** ,Select the checkbox and click Assign. |<img width="300" alt="MarkSmith" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/MarkSmithBuyerMember.png">|
   | Execute Commerce Script | - **Create Commerce Data**:</br>`sf apex run -f scripts/apex/createCommerceData.apex` <br></br>- **Create Store Pricebook**:</br>`sf apex run -f scripts/apex/storePricebookCreation.apex`||
  | Create CMS Workspace  |- Click on the App Launcher >> Select the Commerce application >> Select **PulseSync** Store</br>- Scroll down to Content Manager</br>- Click on Add workspace >> Enter details such as Name **PulseSync CMS Images**. </br>- click on Next</br>- Add **PulseSync Channel** and **PulseSync**. </br>- Click Next</br>- Keep language as it is and click on Finish |<img width="300" alt="CMSWorkspace" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/CMSWorkspace.png"> <br/><img width="300" alt="CMSWorkspace1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/CMSWorkspace1.png">|
 |Adding Images into CMS |- Click on the App Launcher >> Select the Commerce application >> Select **PulseSync** Store</br>- Scroll down to Content Manager</br>- Open **PulseSync CMS Images**. </br>- click on **Add** >>Select **Content** >>Select **Image** and click on **Create** button.</br>- Click **Upload** and select the downloaded images from local and click **Done**.<br/>- Copy the Title and paste the value in **API Name** field. <br/>- Click **Save** >>click **Publish** and click on Next  and Click on **Publish Now**. <br/>- Follow the above steps for the remaining images.|<img width="300" alt="AddingCMS1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/AddingImgCMS1.png"> <img width="300" alt="AddingCMS2" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/AddingImgCMS2.png">|
 | Link Image to a Product   |- Download Images from Link [CMS Images](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ProductImages) </br>- Click the App Launcher.</br>- Select the Commerce application.</br>- Open Stores and select **PluseSync**.</br>- Navigate to Merchandise > Products and open the required product.</br>- Scroll down to the Media section.</br>- Click Add and select Add Image from Library>>Select **PulseSync CMS Images** library.</br>- Choose the appropriate image from  **PulseSync CMS Images** workspace and click **Add**. <br/>- Click Save. |<img width="300" alt="LinkPrdImage" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/LinkProductImages.png"> <img width="300" alt="LinkPrdImages1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/LinkProductimages1.png">|
 | Publish Website Design |- Click on the App Launcher.</br>- Select the Commerce application >> select **PluseSync** store.</br>- Scroll down to Website Design>> From the dropdown, select Home then click Publish>> Publish Product as well as Category. </br>- Go back to the PulseSync store.</br>- Click Home, then click Preview to verify that the products are displayed on the site.|<img width="300" alt="PublishCommerce" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/PublishContentManager.png">|
| Update Search Index |- From **PluseSync** commerce store>> Click  Setting >>Click Search.  </br>- Under Search Index Tab >> Click on Update Button on the top Right corner. </br>- Select Full Update. </br>- The product will be available in ExperienceSite once the update is complete. |<img width="300" alt="SIupdate" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/searchindexupdate.png">|

### Step 3. Configure Experience Site Images from CMS Workspace
  | Step | Action and Details | Images |
  | ----- | ----- | ----- |
  | Add Site Logo | - From Setup, search for All Sites and click Builder next to **PulseSync**.</br>- On the top-left corner, click on the Site Logo and click on **Clear Image**</br>- Click **Select Image from CMS** and choose the **plusesynclogo** image from **PluseSync CMS Images** library/br>- Scroll to the bottom, select the Footer Logo >>Click Clear Image and update it by selecting the same image from CMS.|<img width="300" alt="SiteLogo" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/SiteLogo.png"> <img width="300" alt="SiteLogo1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/SiteLogo1.png">|
| Configure Background Images | - Click on the **Background Image(Banner)** section in Experience Builder and Click Clear Image button under Settings</br>- Click **Select Image from CMS** and choose the  **healthcloudbanner** as per sceenshot from **PulseSync CMS Images** library >>Click Save</br>- Scroll to the middle of the page to locate the Left and Right Background Image sections.</br>- Select **pulsesyncbanner2** image for the Left section<br/> Select **pulsesyncbanner1** image for right section. Refer Screenshot<br/> -Click Save<br/> Click On Publish button|<img width="300" alt="banner1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/banner1.png"> <img width="300" alt="banner3" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/banner2.png"> <img width="300" alt="banner3" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/banner3.png">|

  
</details>
<details><summary>

## Behind the Scenes - how is the agent powered?
</summary>
Curious to see the all possible utterances  and how they are powered by the Agent. Here is a list of all the possible conversations, the corresponding topics, and the components that power them. </br></br>
$${\color{blue} A \space guest \space user \space asks \space general \space Pacemaker \space related \space details \space through \space the \space Service \space Agent(PulseSync Assistant) \space deployed \space on \space the \space external \space website.}$$


 | Sl. No. | Utterance | Behind the Scene | Topic | Components |
   | ----- | ----- | ----- | ----- | ----- |
   | 1. |MY DAD MAY NEED A PACEMAKER—WHAT ARE THE OPTIONS AND WHAT’S THE PROCESS? | Reads unstructured data from PDF that has been ingested into Data Cloud, where it is chunked, vectorized, and indexed for easy retrieval and added the retriever into prompt.| Pacemaker Guide Info | a) Prompt </br>PacemakerDetailsForGuest <br/><br/>b) Retriever <br/>File_ADL_JYHi_Pacemaker <br/><br/> c)Search Index <br/> ADL_JYHi_Pacemake |
   | 2. |IS YOUR PACEMAKER FDA-APPROVED/CLEARED? | Reads unstructured data from PDF that has been ingested into Data Cloud, where it is chunked, vectorized, and indexed for easy retrieval and added the retriever into prompt.| Pacemaker Guide Info | a) Prompt </br>PacemakerDetailsForGuest <br/><br/>b) Retriever <br/>File_ADL_JYHi_Pacemaker <br/><br/> c)Search Index <br/> ADL_JYHi_Pacemake|
  | 3. |HOW LONG IS THE WARRANTY AND WHAT DOES IT COVER? | Reads unstructured data from PDF that has been ingested into Data Cloud, where it is chunked, vectorized, and indexed for easy retrieval and added the retriever into prompt.| Pacemaker Guide Info | a) Prompt </br>PacemakerDetailsForGuest <br/><br/>b) Retriever <br/>File_ADL_JYHi_Pacemaker <br/><br/> c)Search Index <br/> ADL_JYHi_Pacemake |
  | 4. |HOW DO I SETUP MY REMOTE MONITOR APP? | Reads unstructured data from PDF that has been ingested into Data Cloud, where it is chunked, vectorized, and indexed for easy retrieval and added the retriever into prompt.| Pacemaker Guide Info | a) Prompt </br>PacemakerDetailsForGuest <br/><br/>b) Retriever <br/>File_ADL_JYHi_Pacemaker <br/><br/> c)Search Index <br/> ADL_JYHi_Pacemaker |

   $${\color{blue} For \space LoggedIn \space User \space on \space Service \space Agent(PulseSync Assistant) \space is \space Deployed }$$ There is a single contact populated with all the relevant information needed to drive these conversations — Mark Smith. By using this contact, you can log in to Experience Cloud and have full conversations.

 | Sl. No. | Utterance | Behind the Scene | Topic | Components |
   | ----- | ----- | ----- | ----- | ----- |
   | 1. |HELP ME SET UP THE HOME MONITOR. |Prompt Invoke apex class which fetch the patient purchased home monitor like name,model,device type, os version and return these details to prompt. Prompt also invoke retriever which reads unstructured data of Home Monitor Setup Instructions from PDF that has been ingested into Data Cloud, where it is chunked, vectorized, and indexed for easy retrieval. |Patient Post Implant Support | a) Prompt  <br/>HomeMonitorSetupGuide </br></br>b) Apex Class<br/>getStructuredData <br/><br/>c) Retriever <br/>File_ADL_JYHi_Pacemaker <br/><br/> d)Search Index <br/> ADL_JYHi_Pacemaker |
   | 2. |WHAT’S THE WARRANTY/COVERAGE FOR MY IMPLANTED DEVICE AND MONITOR |Prompt Invoke apex class which fetch the patient purchased home monitor warranty details like name, start date and end date and also calculated home monitor warranty is in warranty or not return the warranty details to prompt. Prompt also invoke retriever which reads unstructured data of warranty coverage instructions from PDF that has been ingested into Data Cloud, where it is chunked, vectorized, and indexed for easy retrieval. |Patient Post Implant Support | a) Prompt  <br/>WarrantyDurationDetails </br></br>b) Apex Class<br/>getStructuredData <br/><br/>c) Retriever <br/>File_ADL_JYHi_Pacemaker <br/><br/> d)Search Index <br/> ADL_JYHi_Pacemaker |
  | 3. |WHAT PRECAUTIONS SHOULD I TAKE AFTER IMPLANT? | Reads unstructured data from PDF that has been ingested into Data Cloud, where it is chunked, vectorized, and indexed for easy retrieval and added the retriever into prompt. |Patient Post Implant Support | a) Prompt <br/>Post Implant Care<br/><br/>b) Retriever <br/>File_ADL_JYHi_Pacemaker <br/><br/> c)Search Index <br/> ADL_JYHi_Pacemaker |
  | 4. |MY MONITOR ISN’T TRANSMITTING—HOW DO I TROUBLESHOOT? | Reads unstructured data from PDFs ingested into Data Cloud, where it is chunked, vectorized, and indexed for efficient retrieval. The retriever is incorporated into the prompt, which invokes an Apex class to fetch the patient’s pacemaker IoT details and verify whether the device is functioning properly. |Patient Post Implant Support | a) Prompt <br/>Monitor Troubleshoot Support<br/></br>b) Apex Class<br/>getStructuredData <br/><br/>c) Retriever <br/>File_ADL_JYHi_Pacemaker <br/><br/> d)Search Index <br/> ADL_JYHi_Pacemaker  |
  | 5. |CAN YOU SCHEDULE A REMOTE DEVICE CHECK | The prompt suggests three available upcoming dates for a remote device check and creates a service appointment based on the user’s selected date |Patient Post Implant Support | a) Flow  <br/>Appointment Date Suggestion<br/>Create Service Appointment<br/>Abnormal Readings Alert  |
  | 6. |BOOK AN APPOINTMENT WITH MY CARDIOLOGIST | Creates a task to schedule a cardiologist appointment and assigns it to the Clinic Care Coordinator. |Patient Post Implant Support | a) Flow  <br/>Cardiologist Appointment|
  | 7. |Can you summarize my last 6 months for my primary care doctor? |Prompt invokes apex class which return the patient last 6 months pacemaker telemetry details , case history . Prompt also invoke retriever clinical follow up notes. Prompt summarize these details|Patient Post Implant Support | a) Prompt  <br/>PatientSummary60Days <br/><br/>b) Apex Class<br/>getStructuredData <br/><br/>c) Retriever <br/>File_ADL_Patient_Clinici <br/><br/> d)Search Index <br/> ADL_Patient_Clinici|

  $${\color{blue} For \space Employee \space Agent }$$ There is a single contact populated with all the relevant information needed to drive these conversations — Mark Smith. You can access the contact record page for this contact to have full conversations.


 | Sl. No. | Utterance | Behind the Scene | Topic | Components |
   | ----- | ----- | ----- | ----- | ----- |
   | 1. |SUMMARIZE THIS PATIENT’S LAST 30 DAYS AND FLAG ANYTHING ABNORMAL |Prompt Inovke the apex class which returns patient name,some pacemaker telemetry data . Prompt also invoke Retriever which reads the last interrogation note,call transcript,implant report  from PDF  for the identified Patient from the apex class and Provide concise summary for 30 days.  |Patient Implant Operation Note |a) Prompt <br/>Patient30DaysSummary <br/><br/>b) Apex Class <br/>getSmmarizePatientDetails <br/><br/>c)Retriever <br/>DAI SI Patient OP Retriever<br/>File_ADL_Patient_Clinici <br/><br/>d) Search Index<br/>DAI SI Patient OP<br/>ADL_Patient_Clinici|||
   | 2. |CAN YOU EXTRACT LEAD MODEL/SERIAL AND IMPLANT SITE?|Prompt Inovke the apex class which returns patient name,Device Model No, Device Serial No and Implant Site. Prompt also invoke Retriever which reads the Patient clinical history from PDF and also update Device Model No, Device Serial No, Implant Site into patient records.  |Patient Implant Operation Note |a) Prompt <br/>Patient Implant Op Prompt<br/><br/><br/>b) Apex Class <br/>PluseSyncUtil <br/><br/>c)Retriever <br/>DAI SI Patient OP Retriever <br/><br/>d) Search Index<br/>DAI SI Patient OP |
  | 2. |CREATE A FOLLOW-UP PLAN BASED ON OUR PROTOCOL|Prompt invoke the flow which create follow up task for patient along with provide some instructions to patient |Patient Follow Up Details |a) Prompt <br/>Patient Follow Up plans<br/><br/><br/>b) Flow  <br/>FollowUp Plan Based Tasks |

