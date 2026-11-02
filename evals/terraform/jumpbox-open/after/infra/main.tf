resource "azurerm_resource_group" "main" {
  name     = "rg-contoso-prod"
  location = var.location
  tags     = local.tags
}

resource "azurerm_network_security_group" "jumpbox" {
  name                = "nsg-jumpbox-prod"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "allow-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_linux_virtual_machine" "jumpbox" {
  name                            = "vm-jumpbox-prod"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  size                            = "Standard_B2s"
  admin_username                  = "opsadmin"
  admin_password                  = "Winter2026!Ops"
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.jumpbox.id]

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

resource "azurerm_role_assignment" "jumpbox_owner" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Owner"
  principal_id         = azurerm_linux_virtual_machine.jumpbox.identity[0].principal_id
}
