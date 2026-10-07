Import-Module ./Suchmachiene.Datenbank/Suchmachiene.Datenbank.psd1 -Force

Get-ChildItem -Path "." -File -Recurse | Register-File

Register-File ./Test.ps1


