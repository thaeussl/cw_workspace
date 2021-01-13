#for l3out 
locals{
  file_csv_l3 = file("${path.module}/L3-OUT.csv")
  input_csv_l3 = csvdecode(local.file_csv_l3)
  infra_l3_values = [
    for row in local.input_csv_l3: 
      {
      "L3Out"  = row.L3Out
      "L3Out_Subnet"  = row.L3Out_Subnet
      "Tenant"  = row.Tenant
      "VRF"  = row.VRF
      "EXTEPG"  = row.EXTEPG
      "VLAN"  = row.VLAN
      "VirtualIP"  = row.VirtualIP
      "PhysicalIPa"  = row.PhysicalIPa
      "PhysicalIPb"  = row.PhysicalIPb
      "RemoteIPAddress"  = row.RemoteIPAddress
      "L3Domain"  = row.L3Domain
      "StaticRoute"  = row.StaticRoute
      "VPC_IPG"  = row.VPC_IPG
      "NODEID_a"  = row.NODEID_a
      "NODEID_b"  = row.NODEID_b
      "Port"  = row.Port
      "RouterID_a"  = row.RouterID_a
      "RouterID_b"  = row.RouterID_b
      "VLANPool"  = row.VLANPool
      "AAEP"  = row.AAEP
      }
  ]
  vlpl_list = distinct([
    for row in local.infra_l3_values: 
      {
      "VLANPool"  = row.VLANPool
      "AAEP"  = row.AAEP
      "L3Domain"  = row.L3Domain
      }
  ])
  l3out_list = distinct([
    for row in local.infra_l3_values: 
      {
      "L3Out"  = row.L3Out
      "L3Out_Subnet"  = row.L3Out_Subnet
      "Tenant"  = row.Tenant
      "VRF"  = row.VRF
      "EXTEPG"  = row.EXTEPG
      "VLAN"  = row.VLAN
      "VirtualIP"  = row.VirtualIP
      "RemoteIPAddress"  = row.RemoteIPAddress
      "L3Domain"  = row.L3Domain
      "StaticRoute"  = row.StaticRoute
      "VPC_IPG"  = row.VPC_IPG
      "Port"  = row.Port
      "VLANPool"  = row.VLANPool
      "AAEP"  = row.AAEP
      }
  ])
}  


provider "aci" {
  # cisco-aci user name
  username = "admin"
  # cisco-aci password
  password = "cwacilab"
  # cisco-aci url
  url      = "https://172.20.187.139"
  insecure = true
}

resource "aci_vlan_pool" "vlan_pool_list" {
  for_each  = {for vlan_pool in local.vlpl_list : vlan_pool.VLANPool => vlan_pool}
  name  = each.value.VLANPool
  alloc_mode = "dynamic"
}

resource "aci_l3_domain_profile" "l3domain_list" {
  for_each  = {for row in local.vlpl_list : row.L3Domain => row}
  name  = each.value.L3Domain
  relation_infra_rs_vlan_ns = format("uni/infra/vlanns-[%s]-dynamic", each.value.VLANPool)
}

resource "aci_ranges" "vlan_id_l3_list" {
  for_each = {for vlan_id in local.l3out_list : vlan_id.VLAN => vlan_id}
  vlan_pool_dn = format("uni/infra/vlanns-[%s]-dynamic", each.value.VLANPool)
  _from = format("%s%s", "vlan-", each.value.VLAN)
  to = format("%s%s", "vlan-", each.value.VLAN)
  alloc_mode = "static"
}

#bind domain to aaep
/*
method: POST
url: http://172.20.187.139/api/node/mo/uni/infra/attentp-AAEP_INTIN.json
payload{"infraRsDomP":{"attributes":{"tDn":"uni/l3dom-COMMON_L3Dom","status":"created"},"children":[]}}
response: {"totalCount":"0","imdata":[]}
*/
resource "aci_rest" "l3_domain_aaep_bindings" {
  for_each  = {for domain in local.l3out_list : format("%s%s", domain.L3Domain, domain.VRF) => domain}
  path       =  format("api/node/mo/uni/infra/attentp-%s.json", each.value.AAEP)
  payload = <<EOF
  {
   "infraRsDomP":{
      "attributes":{
         "tDn":"uni/l3dom-${each.value.L3Domain}",
         "status":"created"
      },
      "children":[
         
      ]
   }
}
EOF
}

#Create l3outs
resource "aci_l3_outside" "l3out_list" {
  for_each  = {for row in local.l3out_list : row.L3Out => row}
  tenant_dn      = "uni/tn-${each.value.Tenant}"
  name           = each.value.L3Out
  relation_l3ext_rs_l3_dom_att = aci_l3_domain_profile.l3domain_list[each.value.L3Domain].id
}

#aci logical node profile
resource "aci_logical_node_profile" "logical_node_list" {
    for_each  = {for row in local.l3out_list : row.L3Out => row}
    l3_outside_dn = aci_l3_outside.l3out_list[each.value.L3Out].id
    name          = format("%s_NPR",each.value.L3Out)
}

resource "aci_logical_node_to_fabric_node" "logic_to_fabric_node_lista" {
  for_each  = {for row in local.infra_l3_values : format("%s%s", row.NODEID_a, row.L3Out) => row}
  logical_node_profile_dn  = aci_logical_node_profile.logical_node_list[each.value.L3Out].id
  tdn  = "topology/pod-${substr(each.value.NODEID_a, 0, 1)}/node-${each.value.NODEID_a}"
  rtr_id  = each.value.RouterID_a
  rtr_id_loop_back  = "false"
}

resource "aci_logical_node_to_fabric_node" "logic_to_fabric_node_listb" {
  for_each  = {for row in local.infra_l3_values : format("%s%s", row.NODEID_b, row.L3Out) => row}
  logical_node_profile_dn  = aci_logical_node_profile.logical_node_list[each.value.L3Out].id
  tdn  = "topology/pod-${substr(each.value.NODEID_b, 0, 1)}/node-${each.value.NODEID_b}"
  rtr_id  = each.value.RouterID_b
  rtr_id_loop_back  = "false"
}

#static route to logical node
/*
method: POST
url: http://172.20.187.139/api/node/mo/uni/tn-${each.value.Tenant}/out-${each.value.L3Out}/lnodep-${format("%s_NPR",each.value.L3Out)}/rsnodeL3OutAtt-[topology/pod-1/node-1001]/rt-[${each.value.StaticRoute}].json
payload{"ipRouteP":{"attributes":{"dn":"uni/tn-${each.value.Tenant}/out-${each.value.L3Out}/lnodep-${format("%s_NPR",each.value.L3Out)}/rsnodeL3OutAtt-[topology/pod-1/node-1001]/rt-[${each.value.StaticRoute}]","ip":"${each.value.StaticRoute}","rn":"rt-[${each.value.StaticRoute}]","status":"created"},"children":[{"ipNexthopP":{"attributes":{"dn":"uni/tn-${each.value.Tenant}/out-${each.value.L3Out}/lnodep-${format("%s_NPR",each.value.L3Out)}/rsnodeL3OutAtt-[topology/pod-1/node-1001]/rt-[${each.value.StaticRoute}]/nh-[${each.value.RemoteIPAddress}]","nhAddr":"${each.value.RemoteIPAddress}","rn":"nh-[${each.value.RemoteIPAddress}]","status":"created"},"children":[]}}]}}
response: {"totalCount":"0","imdata":[]}
timestamp: 13:20:20 DEBUG 
*/
resource "aci_rest" "static_to_logicnode_a" {
  for_each  = {for domain in local.infra_l3_values : format("%s%s%s", domain.NODEID_a, domain.L3Domain, domain.VRF) => domain}
  path       =  "api/node/mo/uni/tn-${each.value.Tenant}/out-${each.value.L3Out}/lnodep-${format("%s_NPR",each.value.L3Out)}/rsnodeL3OutAtt-[topology/pod-${substr(each.value.NODEID_a, 0, 1)}/node-${each.value.NODEID_a}]/rt-[${each.value.StaticRoute}].json"
  payload = <<EOF
  {
   "ipRouteP":{
      "attributes":{
         "dn":"uni/tn-${each.value.Tenant}/out-${each.value.L3Out}/lnodep-${format("%s_NPR",each.value.L3Out)}/rsnodeL3OutAtt-[topology/pod-${substr(each.value.NODEID_a, 0, 1)}/node-${each.value.NODEID_a}]/rt-[${each.value.StaticRoute}]",
         "ip":"${each.value.StaticRoute}",
         "rn":"rt-[${each.value.StaticRoute}]",
         "status":"created"
      },
      "children":[
         {
            "ipNexthopP":{
               "attributes":{
                  "dn":"uni/tn-${each.value.Tenant}/out-${each.value.L3Out}/lnodep-${format("%s_NPR",each.value.L3Out)}/rsnodeL3OutAtt-[topology/pod-${substr(each.value.NODEID_a, 0, 1)}/node-${each.value.NODEID_a}]/rt-[${each.value.StaticRoute}]/nh-[${each.value.RemoteIPAddress}]",
                  "nhAddr":"${each.value.RemoteIPAddress}",
                  "rn":"nh-[${each.value.RemoteIPAddress}]",
                  "status":"created"
               },
               "children":[
                  
               ]
            }
         }
      ]
   }
}
EOF
}

resource "aci_rest" "static_to_logicnode_b" {
  for_each  = {for domain in local.infra_l3_values : format("%s%s%s", domain.NODEID_b, domain.L3Domain, domain.VRF) => domain}
  path       =  "api/node/mo/uni/tn-${each.value.Tenant}/out-${each.value.L3Out}/lnodep-${format("%s_NPR",each.value.L3Out)}/rsnodeL3OutAtt-[topology/pod-${substr(each.value.NODEID_b, 0, 1)}/node-${each.value.NODEID_b}]/rt-[${each.value.StaticRoute}].json"
  payload = <<EOF
  {
   "ipRouteP":{
      "attributes":{
         "dn":"uni/tn-${each.value.Tenant}/out-${each.value.L3Out}/lnodep-${format("%s_NPR",each.value.L3Out)}/rsnodeL3OutAtt-[topology/pod-${substr(each.value.NODEID_b, 0, 1)}/node-${each.value.NODEID_b}]/rt-[${each.value.StaticRoute}]",
         "ip":"${each.value.StaticRoute}",
         "rn":"rt-[${each.value.StaticRoute}]",
         "status":"created"
      },
      "children":[
         {
            "ipNexthopP":{
               "attributes":{
                  "dn":"uni/tn-${each.value.Tenant}/out-${each.value.L3Out}/lnodep-${format("%s_NPR",each.value.L3Out)}/rsnodeL3OutAtt-[topology/pod-${substr(each.value.NODEID_b, 0, 1)}/node-${each.value.NODEID_b}]/rt-[${each.value.StaticRoute}]/nh-[${each.value.RemoteIPAddress}]",
                  "nhAddr":"${each.value.RemoteIPAddress}",
                  "rn":"nh-[${each.value.RemoteIPAddress}]",
                  "status":"created"
               },
               "children":[
                  
               ]
            }
         }
      ]
   }
}
EOF
}

#logical interface profile
resource "aci_logical_interface_profile" "logical_ipr_list" {
    for_each  = {for row in local.l3out_list : row.L3Out => row}
    logical_node_profile_dn  = aci_logical_node_profile.logical_node_list[each.value.L3Out].id
    name          = format("%s_IPR",each.value.L3Out)
}

/*method: POST
url: http://172.20.187.139/api/node/mo/uni/tn-${each.value.Tenant}/out-${each.value.L3Out}/lnodep-${format("%s_NPR",each.value.L3Out)}/lifp-${format("%s_IPR",each.value.L3Out)}/rspathL3OutAtt-[topology/pod-1/protpaths-${each.value.NODEID_a}-${each.value.NODEID_b}/pathep-[${each.value.VPC_IPG}]].json
payload{"l3extRsPathL3OutAtt":{"attributes":{"dn":"uni/tn-${each.value.Tenant}/out-${each.value.L3Out}/lnodep-${format("%s_NPR",each.value.L3Out)}/lifp-${format("%s_IPR",each.value.L3Out)}/rspathL3OutAtt-[topology/pod-1/protpaths-${each.value.NODEID_a}-${each.value.NODEID_b}/pathep-[${each.value.VPC_IPG}]]","mac":"00:22:BD:F8:19:FF","ifInstT":"ext-svi","encap":"vlan-1112","tDn":"topology/pod-1/protpaths-${each.value.NODEID_a}-${each.value.NODEID_b}/pathep-[${each.value.VPC_IPG}]","rn":"rspathL3OutAtt-[topology/pod-1/protpaths-${each.value.NODEID_a}-${each.value.NODEID_b}/pathep-[${each.value.VPC_IPG}]]","status":"created"},"children":[{"l3extMember":{"attributes":{"addr":"10.0.0.2/29","status":"created","side":"A"},"children":[{"l3extIp":{"attributes":{"addr":"10.0.0.1/29","status":"created"},"children":[]}}]}},{"l3extMember":{"attributes":{"side":"B","addr":"10.0.0.3/29","status":"created"},"children":[{"l3extIp":{"attributes":{"addr":"10.0.0.1/29","status":"created"},"children":[]}}]}}]}}
response: {"totalCount":"0","imdata":[]}*/
resource "aci_rest" "svi_logical_node_list" {
  for_each  = {for domain in local.infra_l3_values : format("%s%s%s", domain.NODEID_a, domain.L3Domain, domain.VRF) => domain}
  path       =  "api/node/mo/uni/tn-${each.value.Tenant}/out-${each.value.L3Out}/lnodep-${format("%s_NPR",each.value.L3Out)}/lifp-${format("%s_IPR",each.value.L3Out)}/rspathL3OutAtt-[topology/pod-${substr(each.value.NODEID_a, 0, 1)}/protpaths-${each.value.NODEID_a}-${each.value.NODEID_b}/pathep-[${each.value.VPC_IPG}]].json"
  payload = <<EOF
  {
   "l3extRsPathL3OutAtt":{
      "attributes":{
         "dn":"uni/tn-${each.value.Tenant}/out-${each.value.L3Out}/lnodep-${format("%s_NPR",each.value.L3Out)}/lifp-${format("%s_IPR",each.value.L3Out)}/rspathL3OutAtt-[topology/pod-${substr(each.value.NODEID_a, 0, 1)}/protpaths-${each.value.NODEID_a}-${each.value.NODEID_b}/pathep-[${each.value.VPC_IPG}]]",
         "mac":"00:22:BD:F8:19:FF",
         "ifInstT":"ext-svi",
         "encap":"vlan-${each.value.VLAN}",
         "tDn":"topology/pod-${substr(each.value.NODEID_a, 0, 1)}/protpaths-${each.value.NODEID_a}-${each.value.NODEID_b}/pathep-[${each.value.VPC_IPG}]",
         "rn":"rspathL3OutAtt-[topology/pod-${substr(each.value.NODEID_a, 0, 1)}/protpaths-${each.value.NODEID_a}-${each.value.NODEID_b}/pathep-[${each.value.VPC_IPG}]]",
         "status":"created"
      },
      "children":[
         {
            "l3extMember":{
               "attributes":{
                  "addr":"${each.value.PhysicalIPa}",
                  "status":"created",
                  "side":"A"
               },
               "children":[
                  {
                     "l3extIp":{
                        "attributes":{
                           "addr":"${each.value.VirtualIP}",
                           "status":"created"
                        },
                        "children":[
                           
                        ]
                     }
                  }
               ]
            }
         },
         {
            "l3extMember":{
               "attributes":{
                  "side":"B",
                  "addr":"${each.value.PhysicalIPb}",
                  "status":"created"
               },
               "children":[
                  {
                     "l3extIp":{
                        "attributes":{
                           "addr":"${each.value.VirtualIP}",
                           "status":"created"
                        },
                        "children":[
                           
                        ]
                     }
                  }
               ]
            }
         }
      ]
   }
}
EOF
}

resource "aci_external_network_instance_profile" "ext_epg_list" {
   for_each  = {for epg in local.l3out_list : epg.EXTEPG => epg}
   l3_outside_dn  = aci_l3_outside.l3out_list[each.value.L3Out].id
   name           = each.value.EXTEPG
}

resource "aci_l3_ext_subnet" "ext_epg_subnet_list" {
   for_each  = {for epg in local.l3out_list : epg.EXTEPG => epg}
   external_network_instance_profile_dn  = aci_external_network_instance_profile.ext_epg_list[each.value.EXTEPG].id
   ip                                    = each.value.StaticRoute
}
    
#external epg l3out
/*method: POST
url: http://172.20.187.139/api/node/mo/uni/tn-${each.value.Tenant}/out-${each.value.L3Out}/instP-${each.value.EXTEPG}.json
payload{"l3extInstP":{"attributes":{"dn":"uni/tn-${each.value.Tenant}/out-${each.value.L3Out}/instP-${each.value.EXTEPG}","name":"${each.value.EXTEPG}","rn":"instP-${each.value.EXTEPG}","status":"created"},"children":[{"l3extSubnet":{"attributes":{"dn":"uni/tn-${each.value.Tenant}/out-${each.value.L3Out}/instP-${each.value.EXTEPG}/extsubnet-[${each.value.StaticRoute}]","ip":"${each.value.StaticRoute}","scope":"import-security,","aggregate":"","rn":"extsubnet-[${each.value.StaticRoute}]","status":"created"},"children":[]}}]}}
response: {"totalCount":"0","imdata":[]}
resource "aci_rest" "ext_epg_list" {
  for_each  = {for epg in local.infra_l3_values : epg.EXTEPG => epg}
  path       =  "api/node/mo/uni/tn-${each.value.Tenant}/out-${each.value.L3Out}/instP-${each.value.EXTEPG}.json"
  payload = <<EOF
  {
   "l3extInstP":{
      "attributes":{
         "dn":"uni/tn-${each.value.Tenant}/out-${each.value.L3Out}/instP-${each.value.EXTEPG}",
         "name":"${each.value.EXTEPG}",
         "rn":"instP-${each.value.EXTEPG}",
         "status":"created"
      },
      "children":[
         {
            "l3extSubnet":{
               "attributes":{
                  "dn":"uni/tn-${each.value.Tenant}/out-${each.value.L3Out}/instP-${each.value.EXTEPG}/extsubnet-[${each.value.StaticRoute}]",
                  "ip":"${each.value.StaticRoute}",
                  "scope":"import-security,",
                  "aggregate":"",
                  "rn":"extsubnet-[${each.value.StaticRoute}]",
                  "status":"created"
               },
               "children":[
                  
               ]
            }
         }
      ]
   }
}
EOF
}*/
