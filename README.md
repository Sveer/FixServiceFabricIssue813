"# FixServiceFabricIssue813" 

Important:
line 217-228 in Deploy-FabricApplication.ps1 require change package file name and add azure blob account and key.
line 248 in Publish-NewServiceFabricApplication2.ps1 - removed Copy-ServiceFabricApplicationPackage
line 258 in Publish-NewServiceFabricApplication2.ps1 Reqire url to uploaded sfpkg file for Register-ServiceFabricApplicationType 

