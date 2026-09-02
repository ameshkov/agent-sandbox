import { describe, expect, it } from 'vitest';
import { autologonCheckScript, autologonEnableScript } from './windows-autologon.js';

describe('autologonCheckScript', () => {
  it('builds the registry check for the guest user', () => {
    const script = autologonCheckScript('Administrator');
    expect(script).toContain('Get-ItemProperty -Path $w -ErrorAction SilentlyContinue');
    expect(script).toContain("$prop.DefaultUserName -eq 'Administrator'");
    expect(script).toContain("Write-Output 'enabled'");
    expect(script).toContain("Write-Output 'disabled'");
  });

  it('escapes a single quote in the user name', () => {
    expect(autologonCheckScript("O'Brien")).toContain("$prop.DefaultUserName -eq 'O''Brien'");
  });
});

describe('autologonEnableScript', () => {
  it('sets the registry keys and reboots the guest', () => {
    const script = autologonEnableScript('Administrator', 'sandbox1');
    expect(script).toContain("Set-ItemProperty -Path $w -Name AutoAdminLogon -Value '1'");
    expect(script).toContain(
      "Set-ItemProperty -Path $w -Name DefaultUserName -Value 'Administrator'",
    );
    expect(script).toContain("Set-ItemProperty -Path $w -Name DefaultPassword -Value 'sandbox1'");
    expect(script).toContain('shutdown /r /t 0');
  });

  it('escapes single quotes in the password', () => {
    expect(autologonEnableScript('Administrator', "pa'ss")).toContain(
      "Set-ItemProperty -Path $w -Name DefaultPassword -Value 'pa''ss'",
    );
  });
});
