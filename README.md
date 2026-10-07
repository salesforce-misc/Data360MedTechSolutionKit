**A Medical Device Solution Powered by Data 360 – Pulse Sync**</br>
============================
Imagine a pacemaker application that does more than monitor a device; it helps care teams understand the whole patient. Welcome to Pulse Sync! Built with Salesforce Data 360, this solution unifies patient records, pacemaker telemetry, clinical data, and unstructured medical documents into a trusted, actionable profile providing an AI-powered context for faster, more informed decisions. Pulse Sync leverages Data 360, Agentforce, and the Salesforce Platform to provide personalized patient care experiences based on connected medical devices.

The Pulse Sync application showcases Agentforce, Prompt Builder, Document AI, and Notebook AI by leveraging both structured and unstructured data to process patient and device telemetry information. It features a comprehensive patient profile, with the Pulse Sync AI agent using structured and unstructured data to drive contextual conversations.

## 🎥 Product Demo
Watch the video on what is included in this end to end solution before you get started.
[![ ](https://cdn.vidyard.com/thumbnails/nmad0BNFCe5zsy5_CYLgOw/6a5741079bee5e3b63387f_play_button_small.gif)](https://salesforce.vidyard.com/watch/Q8pZYM7bEFN2mdwZw4hoDJ) 

There are two ways to install this solution kit. You can use Claude to run the installation process for you, or you can manually set up the solution in your org. The instructions for both are provided below. 
<details>
<summary><h2>Automated Installation with Claude</h2></summary>

  ### 1. Pre-Deployment Instructions
  To ensure a successful install, please verify your environment is properly configured.
 | Step | Details |
  | ----- | ----- |
  | 1 | Before running the installer, ensure you have Claude, Git, and Visual Studio Code installed, and that you have permission to debug the Chrome browser. |
  | 2 | **Configure Claude Code permissions in VS Code:** Open **VS Code → Settings** and search for **`permission`**. Under **Extensions → Claude Code**, make sure **Claude Code: Allow Dangerously Skip Permissions** is **Enabled/Checked**, and set **Claude Code: Initial Permission Mode** to **`bypassPermissions`**. |
  | 3 |  Create a folder on your local desktop to store the project. This will ensure that any CLAUDE.md file you may have already created won’t interfere with the install.|

 ### 2. Create the Target Org
 | Step | Details |
  | ----- | ----- |
  | 1 |  Request a demo org from the Partner Learning Camp using the link provided https://partnerlearningcamp.salesforce.com/s/demo-org. If you want to use your own developer org, ensure that it has Sales, Service, Experience, Commerce, Field Service, Data Cloud and Loyalty Management licenses/features enabled. |
  | 2 |  Change the log-in user's email to your own email address and make sure to confirm the change.|
  | 3 |  Update your password in the demo org environment.|
  | 4 |  Make a note of your username and password, as you will need them later.|

  ### 3. Clone the Deployment Repository Using  VS Code
 | Step | Details |
  | ----- | ----- |
  | 1 |  Open VS Code  |
  | 2 |  Select 'Clone Git Repository'|
  | 3 |  Enter this Git repository URL in the Command Palette ()  |
  | 4 |  Select the local folder where you want to download the repository (Refer to the Pre-deployment Instructions Section)|
  | 5 |  Once the repository has been downloaded, select “Yes, I trust the authors” when prompted|
  | 6 |  When asked, select “Yes” to open the cloned project folder in VS Code|

 ### 4. Launch Claude Code
 | Step | Details |
  | ----- | ----- |
  | 1 |  Initiate a Claude chat session within VS Code as shown below  |
  | 2 |  To get started, Claude requires some information: The instructions (prompts), an alias (which can be anything), your new Demo Org username and password. |
  | 3 |   To initiate the installation, use the following prompt: <br>"**Install Data 360 Healthcare Installer into Alias: ALIASNAME Username: USERNAME Password: PASSWORD**" </br></br>Replace the alias (can be anything), username and password with your own credentials (from when you created your org) and then press enter to begin the installation. Here is an example: Install Data 360 Healthcare Installer into Alias: Data360MedTechSolution Username: XXX.com Password: XXXXX</br> |
 <img width="700" height="250" alt="claudeicon" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/claudeicon.png">

### 5. Installation Mode Selection
| Step | Details |
 | ----- | ----- |
  | 1 |   You will then receive the following prompt from Claude: <br/> **"The installer needs confirmation on which mode to run. Based on your request for the complete Data360 Healthcare Installer, you'll want Mode 2 which includes all 21 steps - the full Data Cloud + Commerce + Experience Cloud solution. Should I proceed with Mode 2 (the complete installation with all 21 steps)?"** <br/>  We recommend option 2 <br/> Mode 1 = Data Cloud Only <br/> Mode 2 = Data Cloud + Commerce + Experience Cloud + Agentforce |

### 6. Authenticate The Org
| Step | Details |
 | ----- | ----- |
 | 1 | Playwright MCP will launch a new browser window. |
 | 2 | Log in with your org username and password. |
 | 3 | Click **Allow Access**. |

Claude will begin installing everything from the code repository and will orchestrate a series of sub-agents to do the work for you. We recommend  checking on the installation, as there are times when Claude may require additional permissions from you, depending on your settings.  

### 7. Configure MCP Server
 While the MCP Setup skill (/mcp-setup) is running, the installer may pause and ask you to complete the following steps to configure the Salesforce MCP servers: <br/>
  **i.** **Retrieve Consumer Key & Secret from External Client App** 
  
 | Step | Details |
 | ----- | ----- |
 | 1 | Go to Setup → External Client App Manager → **Salesforce_DC_Prod_Org**. |
 | 2 | Open Settings → OAuth Settings → **Consumer Key and Secret** |
 | 3 |Enter the verification code sent to your Salesforce user email. |
 | 4 |Copy the **Consumer Key & Secret and Environment as Sandbox or Production** and provide them to Claude.  |
 | 5 |Claude will register and connect the Salesforce MCP servers. |

<img width="700" height="250" alt="mcpserverconsumerkey" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/mcpserverconsumerkey.png">

 **ii.** **Reload VS Code & Verify MCP Connections**
 
 | Step | Details |
 | ----- | ----- |
 | 1 | Press Ctrl+Shift+P (Windows) or Cmd+Shift+P (Mac)  |
 | 2 | Select **Developer: Reload Window** |
 | 3 | After reload, run **/mcp**  or  **open MCP Servers under Customize** |
 | 4 | Verify that all four Salesforce MCP servers show **Connected** |
 | 5 | Reply **reloaded** to Claude to continue. |
 
 <img width="700" height="250" alt="mcpserverconnected" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/mcpserverconnected.png">

### 8. Claude Moves Forward with Installation
Claude will begin installing everything from the code repository and will orchestrate a series of sub-agents to do the work for you. We recommend  checking on the installation once in a while, as there are times when Claude may require additional permissions from you (Consumer Key/Secret for MCP setup, VS Code window reload after MCP registration), depending on your settings. <br/> 

1. Feature Enablement
2. External Client App Deploy
3. MCP Setup
4. Base Metadata Deploy
5. Data Kit Install
6. Agentforce Data Library
7. Notebook AI
8. Document AI
9. Agent Setup Configuration
10. Prompt Template Add Retriever
11. Assign Permission To App
12. Experience Cloud Setup
13. Commerce Store Enablement
14. Cms Workspace Setup
15. Storefront Publish
16. Embed Service Agent On Experience Site
17. Site Branding Setup
18. Datastream File Upload
19. Refresh Data Cloud Components
20. Copy Field Sync
21. Refresh Data Streams(Optional)

 
**It takes close to more than three hours to complete so let Claude do its work.** Once the installation is complete, navigate to Sales Cloud and search for Mark Smith who is the featured unified profile. From Mark Smith’s profile, navigate to Details, then log in to Experience Cloud to try the logged-in user agent experience. All possible conversations are available in the video and in the “behind the scenes” section of Git repository.

<img width="700" height="250" alt="claudeinstallationsummary" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/claudeinstallationsummary.png">

### 9. Access Experience Cloud and Test the MedTech Solution

Once installation is complete, use Mark Smith, the primary Experience Cloud user, to test the logged-in customer, Commerce, and Service Agentforce experiences.

**Recommended Approach – Log in to Experience as User**

Navigate to the Pulse Sync App → Accounts.
Search for and open Mark Smith.
From the account record, select **Log in to Experience as User**.
The Experience Cloud site opens as **Mark Smith** and is ready for testing.
</br><img width="700" height="250" alt="RecordPageImage" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/accountrecordpagelogin.png"></br>

**Alternative Approach – Direct Experience Cloud Login**

Navigate to the **Mark Smith Experience Cloud User** and update the email address to one you can access.
Reset the password and complete the password reset using the email you receive.
Go to Setup → Domains and copy the Experience Cloud Sites Domain URL.
Open https://ExperienceCloudSitesDomain/PulseSync.
Log in using the Mark Smith username and the newly configured password.
</br><img width="700" height="250" alt="RecordPageImage" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/expsitepage.png"></br>


**Note: Log in to Experience as User is the recommended approach because it provides the quickest way to access the site without resetting the user's email or password.**

</details>

<details>
<summary><h2>Manual Installation</h2></summary>
There are three required steps that allow you to  set up Data 360, import structured and unstructured data, and configure the Employee agent within your Salesforce instance. After completing these steps, the Employee agent will be ready in your org. Steps 4 and 5 are optional — Step 4 deploys the service agent on your own website, and Step 5 deploys it on an Experience Cloud site. The Employee agent has the same functionality as the service agent.

Once the installation is complete, you can navigate to Sales Cloud or the Pulse Sync App and search for "Mark Smith" to view all the unified data that enriches Mark Smith's profile.
<details><summary>

  ## 1. Pre-Deployment Instructions
</summary>

### Step 1. Salesforce Org Setup Requirements for the PulseSync App (5 min)

   To support the PulseSync App, you can either create a new Salesforce org or use an existing Salesforce org that includes the following features and licenses: 

  | Requirement | Details |
  | ----- | ----- |
  | Licenses Required | - Data Cloud</br>- Sales Cloud</br>- Service Cloud</br>- Health Cloud</br>- Health Cloud Platform|
  | Features Required | - Service Agent</br>- Einstein Agent</br>- Copilot</br>- Prompt Builder</br>- Agentforce Data Library</br> - Agentforce Studio</br> - Process Content - Document AI</br> - Notebook AI|


> [!IMPORTANT]
> It is recommended to start with a brand-new environment to avoid conflicts with any previous work you may have done. A developer org can also be used.

### Step 2. Salesforce CLI
- Install VS Code [Download](https://code.visualstudio.com/download)
- [Install the Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) or verify that your installed CLI version is greater than `2.56.7` by running `sf -v` in a terminal.
- Open VS Code >Go to > Extensions >Search for Salesforce Extension Pack >Click Install
- Install Git (Ignore if already installed) [Git](https://git-scm.com/install/)
- Open VS Code > Go to Extensions > Search for Git Extension Pack > Click Install
### Step 3. Enable Data 360.

| Step | Action and Details | Images |
| ----- | ----- | ----- |
| Verify and Enable Data Cloud for Your Org |- Ensure that Data Cloud provisioning is complete before proceeding.</br>- To verify this, navigate to Data Cloud Setup. If provisioning is complete, the page will appear as shown.</br>- If you see a Get Started button, click it and wait for the provisioning process to complete.</br>- This process can take up to 10 minutes.|<img width="450" alt="DatacloudSetup" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Pre-Deployment/DataCloudSetupHome.png">|

### Step 4. Enable Features In Your Environment (20 minutes)

| Step | Action and Details | Images |
| ----- | ----- | ----- |
| Turn on Einstein |- Go to Setup.</br>- In the Quick Find box, search for Einstein Setup.</br>- Click **Turn On Einstein**.|<img width="450" alt="Einstein" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Pre-Deployment/Turn%20on%20Einstein.png?raw=true">|
| Turn on Agentforce |**Note:** You may need to refresh the page to see the Agentforce Agents menu after turning on Einstein.<br><br>- Go to Setup.</br>- In the Quick Find box, type **Agentforce Agents**.</br>- Toggle on **Agentforce**.|<img width="450" alt="Agent1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Pre-Deployment/AgentforceAgents02.png">|
| Modify the Data Cloud Architect Permission Set | - Go to Setup.</br>- In the Quick Find box, Search for and Select **Permission Sets**.</br>- Open the **Data Cloud Architect** permission set.</br>- Click **Data Cloud Data Space Management** under Apps.</br>- Click Edit, **enable the default data space**, and click Save.</br>- Confirm by clicking OK.|<img width="450" alt="DSSpace2" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Pre-Deployment/DC%20Architect%20Data%20Space%20Enable.png">|
| Assign Health Cloud Permission Set Licenses to Admin User |- Click on your **Avatar (Profile Icon)** in the top-right corner.</br> - Select **Settings** (or **My Settings**).</br> - In the left panel, navigate to **Advanced User Details** or **Personal Information**.</br> - Click **View** next to your user details.</br> - Scroll down to **Permission Set License Assignments** section.</br> - Click **Edit Assignments**.</br> - Search for **Health Cloud**, **Health Cloud Platform** licenses and add them.</br>- Click **Save**.||
| Enable Person Account |- Go to Setup.</br>- Enter Person Accounts in the Quick Find box and select **Person Accounts**.</br>- Review the information and steps provided on the Setup page to understand the configuration.</br>- Turn on the Person Accounts toggle.|<img width="450" alt="PS" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Pre-Deployment/PersonAccounts.png">|
| Enable Notebook AI | - Go to Setup. <br>- Search for Feature Manager and  scroll down.<br>- Enable Notebook AI.|<img width="450" alt="DSSpace4" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/FeatureManager(Notebook%20AI).png">|

### Step 5. Base Metadata deployment

1. Clone this repository:

    ```bash
    git clone https://git.soma.salesforce.com/gdevadoss/Data360MedTechSolutionKit.git
    ```

1. Authorize your org using Salesforce CLI.

   Ctrl+Shift+P Select SFDX:Authorize an Org -> Select Project Default -> Enter the Org alias -> Authorize the Org.

1. Assign the following Health Cloud Permission Sets to the Admin User.

   ```bash
   sf org assign permset -n HealthCloudFoundation
   sf org assign permset -n HealthCloudUtilizationManagement
   sf org assign permset -n DiseaseSurveillance
    ```

1. Deploy the base app metadata.

    ```bash
    sf project deploy start -d ps-base
    ```
 
1. Assign the Base Permission Set to Admin User.

   ```bash
   sf org assign permset -n PulseSyncBasePS
    ```
1. Activate Standard PriceBook.

    ```bash
    sf apex run -f scripts/apex/activatePricebook.apex
    ```
1. Replace the Standard Price Book variable in the JSON file with the actual Standard PricebookId by following the steps below in order.
   **Choose PowerShell in VS Code Terminal**


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
  
## 2. Data 360 Configuration
</summary>

### Step 1. Install Datakit and Deploy In Your Environment.

| Step | Action and Details | Image |
|------|-------------|-------|
| Install Data Kit | - **Install Data Kit**:<br>`sf project deploy start -d ps-datacloud`<br><br>- **Open your org** (if it is not already open):<br>`sf org open` | ![](images/datakit.png) |
| Deploy Data Kit Into Your Org | - Go to **Setup**. </br>- Enter **Data Kits** in the **Quick Find** box. </br>- Select **Data360MedTechSolutionKit**. <br>- Click **Datakit Deploy**. <br><br>**Note**: The deployment process may take approximately 25 minutes to complete. You can monitor the progress in the Deployment History section.|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DataKit.png)|

### Step 2. Extract Source files.

| Step | Action and Details | Image |
|------|--------------------|-------|
| Navigate to Documents folder in GitHub Repository | - Open a web browser and go to [GitHub](https://git.soma.salesforce.com/gdevadoss/Data360MedTechSolutionKit/tree/master/MedTechDocuments).<br>- Once inside the repository, you will see the **MedTech Documents** at the root level.<br>- Click on **Pre_Implant_Report** to open the file.<br>- Click on **Download** to save it in your system.<br>**Note**: Follow the above procedure to download the following documents: **Implant_Report**, **Call_Transcript**, **Post_Implant_Report**, **ClinicianNote_DischargeSummary**, **Initial_Interrogation**, **Last_Interrogation**, **Pacemaker Patient Guide**, **Mark_Smith_OP_Note**. Ensure that all files are securely saved to your local system, as they will be required for subsequent processing and configuration steps.| |

### Step 3. Configure Notebook AI Workspace 
| Step | Action and Details | Image |
|------|--------------------|-------|
| Notebook AI Workspace Setup |<br>- Go to App Manager and search for Notebook AI.<br>-Go to Permission Set from Setup, Search for and Click Data Cloud User Permission set<br/>-Click  Clone button and Label the new permission set as **Notebook AI Agent** <br/>- Open Notebook AI Agent permission set -> click  Agent Access and add the Notebook Ai Agent in the permission set <br/>-Assign the user you are using for Notebook Ai to the newly created Notebook AI Agent permission set from Manage Assignments.<br/>- Click on New Notebook. <br>- Provide notebook name as **Diagnosis**. <br>- Under Personal Library, click on the (+) icon. <br>- Upload the following documents: <br>&nbsp;&nbsp;&nbsp;&nbsp;(a) Pre_Implant_Report<br>&nbsp;&nbsp;&nbsp;&nbsp;(b) Implant_Report<br>&nbsp;&nbsp;&nbsp;&nbsp;(c) Call_Transcript<br>&nbsp;&nbsp;&nbsp;&nbsp;(d) Post_Implant_Report<br>&nbsp;&nbsp;&nbsp;&nbsp;(e) ClinicianNote_DischargeSummary<br>&nbsp;&nbsp;&nbsp;&nbsp;(f) Initial_Interrogation<br>&nbsp;&nbsp;&nbsp;&nbsp;(g) Last_Interrogation|<img width="350" alt="Notebook AI" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/notebookaipermissionset.png"> <img width="350" alt="Notebook AI" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/Notebook%20AI%20New.png"><img width="350" alt="Notebook AI Upload" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/Notebook%20AI%20upload.png"><img width="350" alt="Notebook AI Docs" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/Notebook%20AI%20document.png">|
| Activate Notebook AI Agent| - Go to Setup.</br>- In the Quick Find box, search for and select Agentforce Agents.</br>- Click on Notebook AI Agent.</br>- Click Open in builder. </br>- Check whether the agent is activated. If it is not activated, click Activate.|<img width="350" alt="Notebook AI" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/NotebookAI%20Agent.png"><img width="350" alt="Notebook AI" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/NotebookAI%20Agent%20Open.png"><img width="350" alt="Notebook AI" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/NotebookAI%20Activate.png">|
### Step 4. Agentforce Data Library Setup

| Step | Action and Details | Image |
|------|--------------------|-------|
| Agentforce Data Library Setup and Files Upload | - Go to **Setup** .<br>- In the Quick Find box, Search for and Select **Agentforce Data Library**.<br>- Click **New Library**. <br>- Enter the name **Pacemaker Implant Guide** <br>- Click **Save**.<br><br>-Under the Pacemaker Implant Guide library, set Data Type to Files → Click Upload Files.<br>- Choose the **Pacemaker Patient Guide.pdf** file (downloaded in the previous step) → Once the upload is complete, click Done. <br><br>-You can wait until the **Status** updates to **Ready** .This process may take approximately 20 minutes to complete.<br> Follow the steps described above to create the additional libraries: <br/>i.  Create a library named **Patient Clinician Discharge And Interrogation Note**, set the Data Type to **Files** and upload the **ClinicianNote_DischargeSummary.pdf** file that was downloaded in the previous step.<br/>ii. Create a library named **Patient OP**, set the Data Type to **Files** and upload the **Mark_Smith_OP_Note.pdf** file that was downloaded in the previous step. |<img width="350" alt="Notebook AI" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/AgentforceDataLibraryNew.png"><img width="350" alt="Notebook AI" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DataLibraryFileType.png"><img width="350" alt="Notebook AI" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DataLibraryFileUpload.png">|

### Step 5. Configure Document AI.

| Step | Action and Details | Image |
|------|--------------------|-------|
| Create Document AI |- Open Data Cloud App from App launcher.<br/>- Search for and Select Process Content. <br>- Click Document AI.<br/>- Click New button>>Select the **From a Source Object** option>>Click Next.<br/>- Select an Unstructured Data Model Object as **ADL_Patient_Op__dlm**. <br/>- Click Next button.<br>- Enable toggle for  **PDF** under Select File Types and click Next.<br/>- Select **OpenAI GPT-4o** option under Select a Large Language Model and click Next.<br/>- Click **Add** and select New.<br>- Enter Data Lake Object Name as **DAI Patient OP** and the API Name will auto populate.<br/>- Click Next.<br/>- Upload the file as **Mark_Smith_OP_Note.PDF** and select **Using Auto-Extraction** option and click Next.<br/>- Once the fields are extracted, create the remaining field by referring the screenshot.<br/>- Click the Add Field button, enter the Name and select field type as String and again click Add.<br/>- Click Save, then click next. <br/>- Enter Document Schema Name as **DIA Patient OP Schema** and click Save.|<img width="300" alt="docAi1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DocumentAI1.png"> <img width="300" alt="docAi2" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DocumentAI2.png"> <img width="300" alt="docAi3" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DocumentAI3.png"> <img width="300" alt="docAi4" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DocumentAI4.png"> <img width="300" alt="docAi5" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DocumentAIFields1.png"> <img width="300" alt="docAi6" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DocumentAIFields2.png"> <img width="300" alt="docAi7" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DocumentAIFields3.png"> <img width="300" alt="docAi7" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DocumentAISchemaName.png">|
| Create Search Index for Document AI |- Open Data Cloud App from App launcher.<br/>- Search for and Select Search Index>>Click New <br>-Select Easy Setup and click Next<br/>-Select DAI Patient OP DMO and click Next<br/>-Click Save|<img width="300" alt="docAi8" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DocumentAiSi1.png"> <img width="300" alt="docAi9" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DocumentAiSi2.png">|
| Create Retriever for Document AI |- Open Data Cloud App from App launcher.<br/>- Search for and Select AI Models >>Select **Retrieve** >>Click New Retriever<br/>-Select Individual Retriever and click Next<br/>-Click Data Cloud and Select default value for In which data space does the source data reside? , Select DAI Patient Op as Select a data model object,Select DAI Patient OP Search Index >>Click Next<br/>-Select All Documents and click Next<br/>-Click Field Name >> Select Direct Attribute >> Select DIA Patient OP >> Select atrialLeadModel <br/>- Click Add Field >> Add the fields by referring screenshot<br/>-Click Save <br/>-Click Activate|<img width="300" alt="docAire1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DoucmentAiRet1.png"> <img width="300" alt="docAire2" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DoucmentAiRet2.png"> <img width="300" alt="docAire3" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DoucmentAiRet3.png">|

### Step 6. Upload Files for Datastreams.

| Step | Action and Details | Image |
|------|--------------------|-------|
| Update File in Data Cloud |- Navigate to **Data Cloud** from the **App Launcher** <br>- Navigate to **Data Streams** (sometimes under **Data → Data Streams**). <br>- Click  **pacemaker_iot_data** where the **Connection Type** is set to **File Upload**.<br>- Click **Update File** in the Data Stream interface to open the file selection dialog.<br>- Upload the new file:<br>- Browse and select the **pacemaker_iot_data** file that was downloaded in the previous step.<br>- Ensure the file matches the expected format (CSV, JSON, etc.).<br>- Click **Deploy**.<br>- Verify the file in the Data Stream:<br>- Optionally, check **Processing History** or **Deployment History** to ensure the file was ingested successfully without errors.|<img width="300" alt="uploadfile1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DataStream%20Via%20File.png"> <img width="300" alt="uploadfile2" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/UploadFileForDS.png">|
| Data Cloud Copy Field Enrichment Sync | - Navigate to Object Manager.</br>- Search for and Select Contact.</br>- Click  Data Cloud Copy Field.</br>- Select **Pacemaker Patient Health Summary default**<br>- Click **Start Sync**.</br>- In the dialog box, click **Start Sync**.</br>- This process can take up to 15 minutes to complete.</br>- Click Sync History to ensure the status is Complete.</br>**Note:** Ensure that the sync status for each field is verified and confirmed.|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/CopyFieldOnContact.png)![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/CopyFieldVariable.png)![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/CopyFieldStartSync.png) |
| Data Cloud Related List to the Contact | - Go to Object Manager.</br>- Search for and Select Contact.</br>- Go to the Data Cloud Related List tab.</br>- Click New.</br>- Under Data Cloud Object, select **pacemaker_iot_data** and click Next.</br>- Keep the default values and click Next.</br>- Change the related list label to **Pacemaker IOT**.</br>- Check the Contact Layout checkbox.</br>- Check the Add related list to users’ existing record page customizations checkbox.</br>- Click Next.</br> |![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DCRelatedListNew.png)![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DCRelatedListUnified.png)![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DCRelatedListLayout.png)|


### Step 7. Refresh Data 360 Components


| Step | Action and Details | Images |
| ----- | ----- | ----- |
| Refresh Data Stream | - Go to App Launcher</br>- Click on the Data Cloud App</br>- Navigate to the Data Streams tab</br>- For each data stream listed, click the downward arrow on the right-hand side of the data stream name and select Refresh Now</br>- Wait until the status shows Success and verify the Last Processed Records</br>- Follow above steps one by one for all Data Streams: **Account_Home**, **Contact_Home**,**Case_Home**, **Product2_Home**, **Pricebook2_Home**, **PricebookEntry_Home**, **Asset_Home**, **Task_Home**, **Entitlement_Home**, **ServiceAppointment_Home**, **AllergyIntolerance_Home**, **CodeSet_Home**, **CodeSetBundle_Home**, **Medication_Home**, **PatientMedicalProcedure_Home**, **HealthCondition_Home**,**MedicationRequest_Home**|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/DataStream.png)|
| Run Identity Resolution Ruleset | - Go to the **Identity Resolution** tab</br>- Choose and select **Unify Patient IOT Data**</br>- Click **Run Ruleset** |![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/IdentityResolution.png) |
| Run Calculated Insights | - Go to the **Calculated Insights** tab</br>- Choose and select **Pacemaker Latest Transmission**<br>- Click **Publish Now** <br>- Follow the above steps for the following calculated insight :<br/>- **Pacemaker Patient Health Summary** </br>- Click Run Publish Now|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/CalculatedInsight.png)| 
| Publish Segment |- Go to the Segment tab.</br>- Choose and select **Anomalous Pacemaker Battery**. </br>- Click Run Publish Now|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/DataCloud%20Configuration/Segment.png)| 

⚠️ **Important Note:** If you still cannot see the values under Account 360 Record page then follow the above refresh steps again in the same series. 


</details>

<details><summary>

  ## 3. Agentforce Agents Installation
</summary>

### Step 1. Install Agents and Activate

| Step | Action and Details | Image |
|------|-------------|-------|
| Agent Setup and Configuration | - **Install Agents**:<br>`sf project deploy start -d ps-post-pack`<br/>**Note:** If the command throws an error for the FlexiPage<br/> update the key from pacemaker_iot_data__pr to pacemaker_iot_data1__pr <br><br>- **Assign Permission Set to the Default User**:<br>`sf org assign permset -n PulseSyncCustomPS`.<br></br>- **Activate Agent**: <br>`sf agent activate --api-name Clinician_Copilot`<br><br>- **Create Agent User**:<br>`sf apex run -f scripts/apex/createAgentUser.apex`<br><br>- **Create ClinicalCareCoordinator User**:<br>`sf apex run -f scripts/apex/createCareCordinatorUser.apex`<br></br>- **Open your org** (if not already open):</br>`sf org open`.
| Assign User to Service Agent |- Click  Setup <br>-Search for and Select Agentforce Agents.<br>- Click  **PulseMedAssistant** <br/>-Click Agent Access and select canvas mode <br/>-Select the agent user created in previous step under Agent User Record Field<br/>-Click Save <br/>-Click Commit Version<br/>-Click Activate| ![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/agentcommitversion.png)|
| Add Pacemaker Implant Guide Retriever |- Go to **Setup** → enter **Prompt Builder** <br/>Open **Monitor Troubleshoot Support** prompt template</br>- Replace **ADL_PACEMAKER_IMPLANT** with a retriever:</br>&nbsp;&nbsp;i. Click **Insert Resource** → **Retrievers** → **Configure Retrievers**</br>&nbsp;&nbsp;ii. Select the retriever created by the ADL when you **uploaded the file for Pacemaker Implant Guide(Eg:File_ADL_JYHi_Pacemaker )** </br>&nbsp;&nbsp;iii. Under **Search Text**, choose **Free Text** → **Question**</br>&nbsp;&nbsp;iv. For **Output Fields**, select **Chunk** → **Apply and Insert**</br>&nbsp;&nbsp;v. Click **Save As** → **Save as New Version** → **Activate**.<br><br>**Note:** Follow the above step for adding Retriever to the below Prompt Templates:<br/> **i. Post Implant Care** <br/>**ii. PacemakerDetailsForGuest** <br/> **iii.DeviceRegulatoryInfo** <br/>**iv.HomeMonitorSetupGuide** <br/> **v. WarrantyDurationDetails**.|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/PacemakerDetailRetriever.png)![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/NewRetriever.png)![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/RetrieverConfiguration.png)|
| Add Patient Implant Op Retriever |- Go to **Setup** → enter **Prompt Builder** <br/>Open **Patient Implant Op Prompt** prompt template.</br>- Replace **DAI_SI_Patient_OP_Retriever** with a retriever:</br>&nbsp;&nbsp;i. Click **Insert Resource** → **Retrievers** → **Configure Retrievers**</br>&nbsp;&nbsp;ii. Select the retriever created manually for Document AI **(Eg:DAI Patient OP Retriever)** </br>&nbsp;&nbsp;iii. Under **Search Text**, choose **Free Text** → **Id** and **Question**.</br>&nbsp;&nbsp;iv. For **Output Fields**, select **deviceModel**, **deviceSerial**,**implantSite** and **patientName** → **Apply and Insert**</br>&nbsp;&nbsp;v. Click **Save As** → **Save as New Version** → **Activate**.|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/PatientImplantOP.png)|
| Add Patient Summary Retriever | - Go to **Setup** → Enter **Prompt Builder**<br/> Open **Patient30DaysSummary** prompt template<br>- Click on the Apex class and verify if the Input:Id has been assigned to Account Input.</br>- Replace **DAI_PATIENT_OP** with a retriever:</br>&nbsp;&nbsp;i. Click **Insert Resource** → **Retrievers** → **Configure Retrievers**</br>&nbsp;&nbsp;ii. Select the retriever created by Document AI **(Eg:DAI Patient OP Retriever)** </br>&nbsp;&nbsp;iii. Under **Search Text**, choose **Free Text** → **Id**.<br><br>- Replace **ADL_PATIENT_CLINIC** with a retriever:</br>&nbsp;&nbsp;i. Click **Insert Resource** → **Retrievers** → **Configure Retrievers**</br>&nbsp;&nbsp;ii. Select the retriever created by the ADL when you **uploaded the file for Patient_Clinician_Notes(Eg:File_ADL_Patient_Clinici)** </br>&nbsp;&nbsp;iii. Under **Search Text**, choose **Free Text** → **Question**→ **Apply and Insert**</br>&nbsp;&nbsp;iv. Click **Save As** → **Save as New Version** → **Activate**|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/PatientSummary1.png)![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/PatientSummary2.png)|
| Add Patient 6 Month Summary Retriever  |- Go to **Setup** → enter **Prompt Builder**<br/> Open **PatientSummary60Days** prompt template.</br>- Replace **ADL_PATIENT_CLINIC** with a retriever:</br>&nbsp;&nbsp;i. Click **Insert Resource** → **Retrievers** → **Configure Retrievers**</br>&nbsp;&nbsp;ii. Select the retriever created by the ADL when you **uploaded the file for Patient_Clinician_Notes(Eg:File_ADL_Patient_Clinici )** </br>&nbsp;&nbsp;iii. Under **Search Text**, choose **Free Text** → **Id** and **Question**.</br>&nbsp;&nbsp;iv. For **Output Fields**, select **Chunks** → **Apply and Insert**</br>&nbsp;&nbsp;v. Click **Save As** → **Save as New Version** → **Activate**.||
| Assigning Permission to App | - Go to Setup <br>- Search for **App Manager**<br>- Click  **Pulse Sync App**<br>- Click  **Edit** from arrow.<br>- Click **User Profiles**<br>- Search **System Administrator** from Available Profiles and select it and click on right arrow -> so it will be present under **Selected Profiles** <br>- Click on Save|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/PulsesyncApp.png)![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/PulseSyncSystemadmin.png)|
| Activate Account Record Page | - Go to Setup. <br>- In Quick Find, Search for and Select **Lightning App Builder**.<br>- Click  **Patient Account Page** from the list.<br>- Click on **Edit**. <br>- In the top-right corner, click **Activate**. <br>- Click on **Assign as Org Default** in the popup <br>- Click **Save**|![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/PulsesyncRecordPage.png)![image](https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/PulsesyncOrgDefault.png)|


</details>
<details><summary>

 ## 4. (Optional) Configure Commerce Cloud and Experience Cloud
</summary>


### Step 1. Experience Cloud Setup

  | Step | Action and Details | Images |
  | ----- | ----- | ----- |
   | Enable Commerce Cloud | - From Setup, enter **Commerce** in the Quick Find box.</br>- Select **Settings** under **Commerce**.</br>- Turn on **Enable Commerce**. |<img width="300" alt="CommerceEnable" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/CommerceEnable.png">|
   | Create an Experience Site | - From Setup, enter **Digital Experiences** in the Quick Find box -> Select **All Sites** under **Digital Experiences**.</br>- Click New to open the Creation wizard with template options and Select the **Commerce Store (LWR)** template.</br>- Click Get Started.</br>- Provide Store Name as ‘PulseSync’ and ensure the URL ends with /PulseSync</br>- Click Create. Your site will be created in Preview status. | <img width="300" alt="CommerceLwrTemplate" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/CommerceLwrTemplate.png"> <img width="300" alt="CommerceLwrTemplate" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/CommerceLwrTemplate1.png">|
   | Activate Site | - From Setup, enter **Digital Experiences** and select **All Sites** under **Digital Experiences**.</br>- Click Workspaces next to **PulseSync**.</br>- Select Administration.</br>- In Settings, click Activate and confirm by clicking OK.</br>- Your site will now be live and fully set up.|<img width="300" alt="ExpSiteActive" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/ExpSiteActive.png?raw=true">|
   | Register Site Setting |- Go to Domains from Setup under User Interface and copy the Experience Cloud Sites Domain.</br>- Search for and Select **Sites** from User Interface >>Click on the **Site Label** for **ESW Web Deployment site**.</br>- Under Trusted Domains for Inline Frames, click New.</br>- Paste the copied domain URL and click Save. |<img width="300" alt="registersite" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/registersitedomain.png"> <img width="300" alt="registersite1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/RegisterDomain1.png"> |
   | Digital Experience  |- From Setup, search for Digital Experiences and click on Settings under Digital Experiences.</br>- Select the **Allow using standard external profiles for self-registration, user creation, and login** checkbox </br>-  click OK in the dialog box and Click Save .|<img width="300" alt="SiteSetting" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/SiteSettings.png">|
   | Experience Cloud Automated Setup | - **Deploy Experience cloud package**</br>`sf project deploy start -d ps-pd-experience-optional`<br></br>- **Create Experience Site User**<br>`sf apex run -f scripts/apex/createSiteUser.apex` ||
   | CORS Configuration | - From Setup, search for CORS and click New.</br>- Add **https://*.my.salesforce-scrt.com** and Save.</br>- From Setup, Search for and Select **Domains** under **User Interface**.</br>- Copy the **My Domain URL** and the **Experience Cloud Sites Domain**.</br>- Add both URLs separately in CORS, **ensure it starts with https://** and click Save.<br/>- Click **New** and Add.<br> _https://*.my.salesforce-scrt.com_|<img width="300" alt="Cors1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/Cors1.png"> <img width="300" alt="CorsExt" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentExternalWebsite/corsexternalsite.png">|
  |Trusted URL | - Go to **Domains** under **User Interface** and copy the Experience Cloud Sites Domain.</br>- From Setup, search for Trusted URLs and click New Trusted URL.</br>- Enter the Name as **PulseSync** and paste the copied domain URL, ensuring it starts with https://.</br>- Make sure to select all the CSP directives. </br>- Click Save. |<img width="300" alt="TrustedUrl1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/TrustedUrl.png">|
|Update CSP Trusted URL | - Go to **Domains** under **User Interface** and copy the Experience Cloud Sites Domain url.</br>- From Setup, Search for and Select All Sites and Click Builder next to **PulseSync**. </br>- Click Setting and click **Security & Privacy** <br/>- Scroll down to Trusted Sites for Scripts section and edit the **Site Url** and paste the Experience Cloud Sites Domain URL and click on Update. <br/>- Publish the Site |<img width="300" alt="CSP" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/UpdateCSPURL.png">|
### Step 2. Commerce Cloud Setup
  | Step | Action and Details | Images |
  | ----- | ----- | ----- |
  | Enable Search Index | - Click on App Launcher, Search for and Select Commerce application.</br>- Scroll down to Settings and expand it</br>- Click on Search</br>- Use the toggle to turn on Automatic Updates.|<img width="300" alt="Si" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/CommerceSI.png">|
  | Enable Guest access | - Click on the App Launcher, Search for and Select the Commerce application. </br>- On the left-hand side, click Stores under Settings. </br>- Navigate to the Buyer Access tab. </br>- Scroll down to the Guest Access section. </br>- Click on **Enable button** and click on Continue.|<img width="300" alt="GuestAccess" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/GuestAccessEnable.png">|
  | Assign Guest User to Buyer Group | - In the **PulseSync** store,  On the left-hand side, click Stores under Settings >> Click on Buyer Access Tab </br>- Click on **PulseSync Guest Buyer Profile** under Guest Access .</br>- Click on Related ->Click on Buyer Groups , Click on Assign Button <br/> -Select the checkbox for **PulseSync Buyer Group** and click on Assign Button|<img width="300" alt="GuestBuyerGrp" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/GuestBuyerGrpMember.png">|
  | Assign Customer User to Buyer Group |- Go to the App Launcher, search for Accounts, and open it.</br>- Open the **Mark Smith** account and click **Enable as Buyer**.</br>- In **PulseSync** commerce store, navigate to Settings > Buyer Access.</br>- Open the **PulseSync Buyer Group**.</br>- Under Buyer Group Members, click Assign, search for **Mark Smith** ,Select the checkbox and click Assign. |<img width="300" alt="MarkSmith" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/MarkSmithBuyerMember.png">|
   | Execute Commerce Script | - **Create Commerce Data**:</br>`sf apex run -f scripts/apex/createCommerceData.apex` <br></br>- **Create Store Pricebook**:</br>`sf apex run -f scripts/apex/storePricebookCreation.apex`||
  | Create CMS Workspace  |- Click on the App Launcher >> Select the Commerce application >> Select **PulseSync** Store</br>- Scroll down to Content Manager</br>- Click on Add workspace >> Enter details such as Name **PulseSync CMS Images**. </br>- click on Next</br>- Add **PulseSync Channel** and **PulseSync**. </br>- Click Next</br>- Keep language as it is and click on Finish |<img width="300" alt="CMSWorkspace" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/CMSWorkspace.png"> <br/><img width="300" alt="CMSWorkspace1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/CMSWorkspace1.png">|
 |Adding Images into CMS |- Download Images from Link [CMS Images](https://git.soma.salesforce.com/gdevadoss/Data360MedTechSolutionKit/tree/master/ProductImages) </br>- Click on the App Launcher >> Select the Commerce application >> Select **PulseSync** Store</br>- Scroll down to Content Manager</br>- Open **PulseSync CMS Images**. </br>- click on **Add** >>Select **Content** >>Select **Image** and click on **Create** button.</br>- Click **Upload** and select the downloaded images from local and click **Done**.<br/>- Copy the Title and paste the value in **API Name** field. <br/>- Click **Save** >>click **Publish** and click on Next  and Click on **Publish Now**. <br/>- Follow the above steps for the remaining images.|<img width="300" alt="AddingCMS1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/AddingImgCMS1.png"> <img width="300" alt="AddingCMS2" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/AddingImgCMS2.png">|
 | Link Image to a Product   |- Click the App Launcher.</br>- Select the Commerce application.</br>- Open Stores and select **PulseSync**.</br>- Navigate to Merchandise > Products and open the required product.</br>- Scroll down to the Media section.</br>- Click Add and select Add Image from Library>>Select **PulseSync CMS Images** library.</br>- Choose the appropriate image from  **PulseSync CMS Images** workspace and click **Add**. <br/>- Click Save. |<img width="300" alt="LinkPrdImage" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/LinkProductImages.png"> <img width="300" alt="LinkPrdImages1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/LinkProductimages1.png">|
 | Publish Website Design |- Click on the App Launcher.</br>- Select the Commerce application >> select **PulseSync** store.</br>- Scroll down to Website Design>> From the dropdown, select Home then click Publish>> Publish Product as well as Category. </br>- Go back to the PulseSync store.</br>- Click Home, then click Preview to verify that the products are displayed on the site.|<img width="300" alt="PublishCommerce" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/PublishContentManager.png">|
| Update Search Index |- From **PulseSync** commerce store>> Click  Setting >>Click Search.  </br>- Under Search Index Tab >> Click on Update Button on the top Right corner. </br>- Select Full Update. </br>- The product will be available in ExperienceSite once the update is complete. |<img width="300" alt="SIupdate" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/searchindexupdate.png">|

### Step 3. Configure Experience Site Images from CMS Workspace
  | Step | Action and Details | Images |
  | ----- | ----- | ----- |
  | Add Site Logo | - From Setup, search for All Sites and click Builder next to **PulseSync**.</br>- On the top-left corner, click on the Site Logo and click on **Clear Image**<br/>- Click **Select Image from CMS** and choose the **PulseSynclogo** image from **PulseSync CMS Images** library<br/>- Scroll to the bottom, select the Footer Logo >>Click Clear Image and update it by selecting the same image from CMS.|<img width="300" alt="SiteLogo" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/SiteLogo.png"> <img width="300" alt="SiteLogo1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/SiteLogo1.png">|
| Configure Background Images | - Click  **Background Image(Banner)** section in Experience Builder and Click Clear Image button under Settings<br/>- Click **Select Image from CMS** and choose the  **healthcloudbanner** as per screenshot from **PulseSync CMS Images** library >>Click Save<br/>- Scroll to the middle of the page to locate the Left and Right Background Image sections.<br/>- Select **pulsesyncbanner2** image for the Left section<br/> Select **pulsesyncbanner1** image for right section. Refer to the Screenshot<br/> -Click Save<br/>-Click Publish button|<img width="300" alt="banner1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/banner1.png"> <img width="300" alt="banner3" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/banner2.png"> <img width="300" alt="banner3" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/ExperienceSiteImages/banner3.png">|

### Step 4.  Deploy Service Agent on an Experience Site

| Step | Action and Details | Image |
|------|-------------|-------|
| Enable Messaging Channel | - Navigate to Setup >> Search for and Select **Messaging Setting**. </br>- Toggle on **Messaging**.|<img width="300" alt="MSEnable" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentExternalWebsite/MessagingSettingEnable.png">|
| Configure Site Setting |- In Setup, Search for and Select **Sites** and click **Register My Salesforce Site Domain**.|<img width="300" alt="RegisterDomain" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentExternalWebsite/RegisterDomain.png"> |
| Embedded Service Package Installation|- **Install Embedded Service Package**:</br>`sf project deploy start -d ps-embeddedservice`.||
| Activate Messaging Channel |- **Activate Messaging Channel**:</br>`sf apex run -f scripts/apex/activateMessagingChannel.apex`||
| Publish ESA | - Click on Setup. </br>- In Quick Find, Search for and Select Embedded Service Deployments.</br>- Click on **ESA Web Deployment**. </br>- Click on 'Publish' button. </br>- Hold for a confirmation Message. |<img width="300" alt="RouteEsa" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentExternalWebsite/Routetoeasflow.png?raw=true">|
| Create a New Version of Omni-Channel Flow  |- Click on Setup.</br>- Search for Flows in the Quick Find box and select it.</br>- Open the flow **Route Conversations to Agentforce Service Agents**.</br>- Deactivate the flow and open the **Route to Service Agent** element.</br>- Refresh the Service Channel by selecting a different option and then reselect **Live Messaging**.</br>- Set Route To as **Agentforce Service Agent** and choose **PulseMedAssistant**.</br>- In Fallback Queue ID, remove the existing queue and reselect the same queue.</br>- Click Save As New Version, then click **Activate**.  |<img width="300" alt="RouteEsa" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentExternalWebsite/Routetoeasflow.png?raw=true">|

### Step 5.Access Experience Cloud and Test the MedTech Solution

Once installation is complete, use Mark Smith, the primary Experience Cloud user, to test the logged-in customer, Commerce, and Service Agentforce experiences.

**Recommended Approach – Log in to Experience as User**

Navigate to the Pulse Sync App → Accounts.
Search for and open Mark Smith.
From the account record, select **Log in to Experience as User**.
The Experience Cloud site opens as **Mark Smith** and is ready for testing.
</br><img width="700" height="250" alt="RecordPageImage" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/accountrecordpagelogin.png"></br>

**Alternative Approach – Direct Experience Cloud Login**

Navigate to the **Mark Smith Experience Cloud User** and update the email address to one you can access.
Reset the password and complete the password reset using the email you receive.
Go to Setup → Domains and copy the Experience Cloud Sites Domain URL.
Open https://ExperienceCloudSitesDomain/PulseSync.
Log in using the Mark Smith username and the newly configured password.
</br><img width="700" height="250" alt="RecordPageImage" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentforceAgentImages/expsitepage.png"></br>


**Note: Log in to Experience as User is the recommended approach because it provides the quickest way to access the site without resetting the user's email or password.**
  
</details>
<details><summary>

 ## 5. (Optional) Deploy the Service Agent to an External Website
</summary>

### Step 1. Embedded Service Messaging Setup and Configuration

| Step | Action and Details | Image |
|------|-------------|-------|
| Enable Messaging Channel | - Navigate to Setup >> Search for and Select **Messaging Setting**. </br>- Toggle on **Messaging**.|<img width="300" alt="MSEnable" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentExternalWebsite/MessagingSettingEnable.png">|
| Embedded Service Package Installation|- **Install Embedded Service Package**:</br>`sf project deploy start -d ps-embeddedservice`.
| Configure Site Setting |- In Setup, Search for and Select **Sites** and click **Register My Salesforce Site Domain**.</br>- After registration, open the Embedded Service Deployment and locate the Site Endpoint that starts with **ESW** (ESA Web Deployment).</br>- Click the endpoint link to open the site settings.</br>- Under Trusted Domains for Inline Frames, click **Add Domain**.</br>- Enter the same external website URL used earlier.</br>- Click Save.|<img width="300" alt="RegisterDomain" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentExternalWebsite/RegisterDomain.png"> <img width="300" alt="RegisterDomain1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentExternalWebsite/RegisterDomain1.png">|
| Activate Messaging Channel |- **Activate Messaging Channel**:</br>`sf apex run -f scripts/apex/activateMessagingChannel.apex`||
| Publish ESA | - Click on Setup. </br>- In Quick Find, Search for and Select Embedded Service Deployments.</br>- Click on **ESA Web Deployment**. </br>- Click on 'Publish' button. </br>- Hold for a confirmation Message. |<img width="300" alt="ESApublish" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentExternalWebsite/ESAPublish.png">|
| Create a New Version of Omni-Channel Flow  |- Click on Setup.</br>- Search for Flows in the Quick Find box and select it.</br>- Open the flow **Route Conversations to Agentforce Service Agents**.</br>- Deactivate the flow and open the **Route to Service Agent** element.</br>- Refresh the Service Channel by selecting a different option and then reselect **Live Messaging**.</br>- Set Route To as **Agentforce Service Agent** and choose **PulseMedAssistant**.</br>- In Fallback Queue ID, remove the existing queue and reselect the same queue.</br>- Click Save As New Version, then click **Activate**.  |<img width="300" alt="RouteEsa" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentExternalWebsite/Routetoeasflow.png?raw=true">|

### Step 2. CORS Configuration

| Step | Action and Details | Image |
|------|-------------|-------|
| Configure CORS Settings | - From Setup, Search for and Select  **CORS** >> click New.</br>- Enter the **external website URL. Do not include a trailing “/”**.</br>- Click **New** and Add.<br>   _https://*.my.salesforce-scrt.com_|<img width="300" alt="CorsExt" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/AgentExternalWebsite/corsexternalsite.png">|


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

 ## 6. (Optional) YouTube Connection Setup
</summary>

### Step 1. Setup YouTube Connection

  | Step | Action and Details | Images |
  | ----- | ----- | ----- |
  | Create YouTube Connection | - Go to Data Cloud Setup >> Search for and Select Other Connectors>>Click New<br/>-Search for **YouTube** and click it >>Provide Name as **YouTube**, Enter Client Id, Client Secret, Refresh Token and Channel Id <br/>-Click Test Connection to verify the connection is established, then click Save |<img width="350" alt="youtube" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Youtube%20Images/youtubeconnection.png">|

  ### Step 2. Create Data Lake Object and Retriever For YouTube

  | Step | Action and Details | Images |
  | ----- | ----- | ----- |
  | Create DLO | - Go to Data Cloud app from App launcher>>Click **Data Lake Object** Tab >>Click New<br/>-Select **From External Files**>>Select **YouTube**>>Click Next<br/>Select the  Connection as **YouTube** >>Select 15 March 2026 as **Creation Date**>>Click Next <br/>-Enter Object Name as **Youtube Pacemaker Videos**>> Select New >>Again enter Object Name as **Youtube Pacemaker Videos** and click Next <br/>-Select **Enable semantic search with system defaults** checkbox and click on Save<br/>-Verify the **YouTube Pacemaker Videos** search index has been created and proceed only after the status is marked Ready.|<img width="350" alt="youtubeDLO" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Youtube%20Images/YoutubeDLO1.png"> <img width="350" alt="youtubeDLO2" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Youtube%20Images/YoutuveDLO2.png">|
  | Create Retriever For YouTube | -Navigate to Data Cloud app from App launcher>>Click **AI Models** Tab >>Click **Retrieve**>>Click New Retriever<br/>-Select **Individual Retriever** >> Click Next<br/>-Click Data Cloud and Select default value for In which data space does the source data reside? , Select **Youtube Pacemaker Videos** as Select a data model object,Select **Youtube Pacemaker Videos** Search Index >>Click Next <br/>-Select All Documents and click Next<br/>-Click Field Name >>  Select Related Attribute >> Select **Youtube Pacemaker Videos Chunk** >> Select **Chunk**<br/>-Click Add Field and add the fields shown in the screenshot <br/>Click Save, then click Activate|<img width="350" alt="youtubeRet" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Youtube%20Images/YoutubeRet1.png"> <img width="350" alt="youtubeRet" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Youtube%20Images/YoutubeRet2.png"> <img width="350" alt="youtubeRet" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Youtube%20Images/YoutubeRet3.png"> <img width="350" alt="youtubesi" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Youtube%20Images/YoutubeSI.png">|

  ### Step 3. Creation of Prompt Template 

  | Step | Action and Details | Images |
  | ----- | ----- | ----- |
  | Create Prompt Template | -Go to Setup>>Search for and Select Prompt Builder>>Select Template Type as **Flex**<br/>-Enter Name as **Pacemaker Video Content Prompt** >> Add an input with the Name **Question** and select **Free Text** as the Source Type>>Click Next<br/>-Refer to the screenshot to add the prompt details<br/>- Place the retriever as shown in the screenshot:</br>&nbsp;&nbsp;i. Click **Insert Resource** → **Retrievers** → **Configure Retrievers**</br>&nbsp;&nbsp;ii. Select the retriever manually created for **Youtube(Eg:Youtube Pacemaker Videos Retriever )** </br>&nbsp;&nbsp;iii. Under **Search Text**, choose **Free Text** → **Question**</br>&nbsp;&nbsp;iv. For **Output Fields**, select **Chunk** → **Apply and Insert**</br>-Click Save, then click Activate|<img width="350" alt="youtubepmp" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Youtube%20Images/youtubeprompt.png"> <img width="350" alt="youtubepmp1" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Youtube%20Images/youtubepromptret.png">|

  ### Step 4. Add the Prompt Template into Agent

  | Step | Action and Details | Images |
  | ----- | ----- | ----- |
  | Create Agent Action | -Go to Setup>>Search for and Select Agentforce Assets>>Click Action >>Click New Agent Action<br/>-Select Action Type as Prompt Template>>Select **Pacemaker Video Content Prompt** and Click Next <br/>-Refer to the screenshot when adding the Agent Action Description and Input Description. For the Output Variable (Prompt Response), select the **Show in conversation** checkbox <br/>-Click Save|<img width="350" alt="youtubeaction" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Youtube%20Images/youtubeaction1.png"> <img width="350" alt="youtubeaction" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Youtube%20Images/youtubeaction2.png">|
  | Create Agent Topic | -Go to Setup>>Search for and Select Agentforce Agents>>Click **PulseSync Assistant** and click open builder>>Deactivate agent<br/>-Click New, select New Subagent, and click Next>>Enter **Pacemaker Post-Op Care Video Content** as the Name <br/>-Enter the **Topic, Description, Scope, and Instructions** as shown in screenshot and click Next<br/>-Select the **Pacemaker Video Content Prompt** action and click Finish.<br/>-Activate the Agent |<img width="350" alt="youtubetopic" src="https://github.com/salesforce-misc/Data360MedTechSolutionKit/blob/main/Youtube%20Images/youtubetopic.png">|
  

  </details>
  </details>
<details><summary><h2> Behind the Scenes - how is the agent powered?</h2></summary>
Curious to see all possible utterances  and how they are powered by the Agent. Here is a list of all the possible conversations, the corresponding topics(Subagent), and the components that power them. </br></br>
$${\color{blue} A \space guest \space user \space asks \space general \space Pacemaker \space related \space details \space through \space the \space Service \space Agent(PulseMedAssistant) \space deployed \space on \space the \space external \space website.}$$


 | Sl. No. | Utterance | Behind the Scene | Topic | Components |
   | ----- | ----- | ----- | ----- | ----- |
   | 1. |MY DAD MAY NEED A PACEMAKER—WHAT ARE THE OPTIONS AND WHAT’S THE PROCESS? | Reads unstructured data from PDF that has been ingested into Data Cloud, where it is chunked, vectorized, and indexed for easy retrieval and added the retriever to the prompt.| Pacemaker Guide Info | a) Prompt </br>PacemakerDetailsForGuest <br/><br/>b) Retriever <br/>File_ADL_JYHi_Pacemaker <br/><br/> c)Search Index <br/> ADL_JYHi_Pacemake  |
   | 2. |IS YOUR PACEMAKER FDA-APPROVED/CLEARED? | Reads unstructured data from PDF that has been ingested into Data Cloud, where it is chunked, vectorized, and indexed for easy retrieval and added the retriever to the  prompt.| Pacemaker Guide Info | a) Prompt </br>PacemakerDetailsForGuest <br/><br/>b) Retriever <br/>File_ADL_JYHi_Pacemaker <br/><br/> c)Search Index <br/> ADL_JYHi_Pacemake|
  | 3. |HOW LONG IS THE WARRANTY AND WHAT DOES IT COVER? | Reads unstructured data from PDF that has been ingested into Data Cloud, where it is chunked, vectorized, and indexed for easy retrieval and added the retriever to the prompt.| Pacemaker Guide Info | a) Prompt </br>PacemakerDetailsForGuest <br/><br/>b) Retriever <br/>File_ADL_JYHi_Pacemaker <br/><br/> c)Search Index <br/> ADL_JYHi_Pacemake |
  | 4. |HOW DO I SETUP MY REMOTE MONITOR APP? | Reads unstructured data from PDF that has been ingested into Data Cloud, where it is chunked, vectorized, and indexed for easy retrieval and added the retriever to the prompt.| Pacemaker Guide Info | a) Prompt </br>PacemakerDetailsForGuest <br/><br/>b) Retriever <br/>File_ADL_JYHi_Pacemaker <br/><br/> c)Search Index <br/> ADL_JYHi_Pacemaker |

   $${\color{blue} For \space Logged-In \space User \space on \space Service \space Agent(PulseMedAssistant) \space is \space Deployed }$$ There is a single contact populated with all the relevant information needed to drive these conversations — Mark Smith. By using this contact, you can log in to Experience Cloud and have full conversations.

 | Sl. No. | Utterance | Behind the Scene | Topic | Components |
   | ----- | ----- | ----- | ----- | ----- |
   | 1. |HELP ME SET UP THE HOME MONITOR. |Prompt invokes an apex class which fetches the patient's purchased home monitor like name,model,device type, os version and returns these details to the prompt. Prompt also invokes a retriever which reads unstructured data of Home Monitor Setup Instructions from PDF that has been ingested into Data Cloud, where it is chunked, vectorized, and indexed for easy retrieval. |Patient Post Implant Support | a) Prompt  <br/>HomeMonitorSetupGuide </br></br>b) Apex Class<br/>getStructuredData <br/><br/>c) Retriever <br/>File_ADL_JYHi_Pacemaker <br/><br/> d)Search Index <br/> ADL_JYHi_Pacemaker |
   | 2. |WHAT’S THE WARRANTY/COVERAGE FOR MY IMPLANTED DEVICE AND MONITOR |Prompt invokes an apex class which fetches the patient's purchased home monitor warranty details like name, start date and end date and also calculates whether the  home monitor warranty is active or inactive and  returns the warranty details to the prompt. Prompt also invokes a retriever which reads unstructured data of warranty coverage instructions from PDF that has been ingested into Data Cloud, where it is chunked, vectorized, and indexed for easy retrieval. |Patient Post Implant Support | a) Prompt  <br/>WarrantyDurationDetails </br></br>b) Apex Class<br/>getStructuredData <br/><br/>c) Retriever <br/>File_ADL_JYHi_Pacemaker <br/><br/> d)Search Index <br/> ADL_JYHi_Pacemaker |
  | 3. |WHAT PRECAUTIONS SHOULD I TAKE AFTER IMPLANT? | Reads unstructured data from PDF that has been ingested into Data Cloud, where it is chunked, vectorized, and indexed for easy retrieval and added the retriever to the prompt. |Patient Post Implant Support | a) Prompt <br/>Post Implant Care<br/><br/>b) Retriever <br/>File_ADL_JYHi_Pacemaker <br/><br/> c)Search Index <br/> ADL_JYHi_Pacemaker |
  | 4. |MY MONITOR ISN’T TRANSMITTING—HOW DO I TROUBLESHOOT? | Reads unstructured data from PDFs ingested into Data Cloud, where it is chunked, vectorized, and indexed for efficient retrieval. The retriever is incorporated into the prompt, which invokes an Apex class to fetch the patient’s pacemaker IoT details and verify whether the device is functioning properly. |Patient Post Implant Support | a) Prompt <br/>Monitor Troubleshoot Support<br/></br>b) Apex Class<br/>getStructuredData <br/><br/>c) Retriever <br/>File_ADL_JYHi_Pacemaker <br/><br/> d)Search Index <br/> ADL_JYHi_Pacemaker  |
  | 5. |CAN YOU SCHEDULE A REMOTE DEVICE CHECK | The prompt suggests three available upcoming dates for a remote device check and creates a service appointment based on the user’s selected date |Patient Post Implant Support | a) Flow  <br/>Appointment Date Suggestion<br/>Create Service Appointment<br/>Abnormal Readings Alert  |
  | 6. |BOOK AN APPOINTMENT WITH MY CARDIOLOGIST | Creates a task to schedule a cardiologist appointment and assigns it to the Clinic Care Coordinator. |Patient Post Implant Support | a) Flow  <br/>Cardiologist Appointment|
  | 7. |Can you summarize my last 6 months for my primary care doctor? |Prompt invokes an apex class which returns the patient's last 6 months pacemaker telemetry details , case history . Prompt also invokes a retriever clinical follow-up notes and summarizes these details.|Patient Post Implant Support | a) Prompt  <br/>PatientSummary60Days <br/><br/>b) Apex Class<br/>getStructuredData <br/><br/>c) Retriever <br/>File_ADL_Patient_Clinici <br/><br/> d)Search Index <br/> ADL_Patient_Clinici|

  $${\color{blue} For \space Employee \space Agent }$$ There is a single contact populated with all the relevant information needed to drive these conversations — Mark Smith. You can access the contact record page for this contact to have full conversations.


 | Sl. No. | Utterance | Behind the Scene | Topic | Components |
   | ----- | ----- | ----- | ----- | ----- |
   | 1. |SUMMARIZE THIS PATIENT’S LAST 30 DAYS AND FLAG ANYTHING ABNORMAL |Prompt invokes the apex class which returns patient name,some pacemaker telemetry data . Prompt also invokes Retriever which reads the last interrogation note,call transcript,implant report  from PDF  for the identified Patient from the apex class and provides a concise summary for 30 days.  |Patient Implant Operation Note |a) Prompt <br/>Patient30DaysSummary <br/><br/>b) Apex Class <br/>getSmmarizePatientDetails <br/><br/>c)Retriever <br/>DAI SI Patient OP Retriever<br/>File_ADL_Patient_Clinici <br/><br/>d) Search Index<br/>DAI SI Patient OP<br/>ADL_Patient_Clinici|||
   | 2. |CAN YOU EXTRACT LEAD MODEL/SERIAL AND IMPLANT SITE?|Prompt invokes an apex class which returns patient name,Device Model No, Device Serial No and Implant Site. Prompt also invokes a Retriever which reads the Patient clinical history from PDF and also updates the  Device Model No., Device Serial No., Implant Site in the patient records.  |Patient Implant Operation Note |a) Prompt <br/>Patient Implant Op Prompt<br/><br/><br/>b) Apex Class <br/>PulseSyncUtil <br/><br/>c)Retriever <br/>DAI SI Patient OP Retriever <br/><br/>d) Search Index<br/>DAI SI Patient OP |
  | 2. |CREATE A FOLLOW-UP PLAN BASED ON OUR PROTOCOL|Prompt invokes the flow which creates a follow-up task for the patient and provides instructions to the patient. |Patient Follow Up Details |a) Prompt <br/>Patient Follow Up plans<br/><br/><br/>b) Flow  <br/>FollowUp Plan Based Tasks |

</details>
