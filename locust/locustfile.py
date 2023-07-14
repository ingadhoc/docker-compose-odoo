from OdooLocust.OdooLocustUser import OdooLocustUser
from locust import task, between
from OdooLocust import OdooTaskSet

import random

# class GenericTest(OdooLocustUser):
#     wait_time = between(0.1, 1)
#     database = "saas_provider"
#     login = "admin"
#     password = "admin"
#     port = 8069
#     protocol = "jsonrpc"

#     @task(10)
#     def read_partners(self):
#         cust_model = self.client.get_model('res.partner')
#         cust_ids = cust_model.search([], limit=80)
#         prtns = cust_model.read(cust_ids, ['name'])

#     tasks = [OdooTaskSet.OdooGenericTaskSet]


class Seller(OdooLocustUser):
    wait_time = between(0.1, 10)
    
    database = "locust_test"
    login = "admin"
    password = "admin"
    port = 8069
    protocol = "jsonrpc"

    # database = "trainp-xxxx-09-06-1"
    # login = "vfuentes@xxxx.com"
    # password = "testtest5"
    # port = 443
    # protocol = "jsonrpcs"

    
    @task(10)
    def read_partners(self):
        cust_model = self.client.get_model('res.partner')
        cust_ids = cust_model.search([('user_ids', '=', False)])
        prtns = cust_model.read(cust_ids)

    @task(5)
    def read_products(self):
        prod_model = self.client.get_model('product.product')
        ids = prod_model.search([])
        prods = prod_model.read(ids)

    @task(20)
    def create_so(self):
        prod_model = self.client.get_model('product.product')
        cust_model = self.client.get_model('res.partner')
        so_model = self.client.get_model('sale.order')

        cust_id = random.choice(cust_model.search([], limit = 30))
        prod_ids = prod_model.search([], limit = 30)
        prod_1 = random.choice(prod_ids)
        prod_2 = random.choice(prod_ids)
        order_id = so_model.create({
            'partner_id': cust_id,
            'order_line': [(0, 0, {'product_id': prod_1,
                                   'product_uom_qty': 1}),
                           (0, 0, {'product_id':prod_2,
                                   'product_uom_qty': 2}),
                          ]
        })
        so_model.action_confirm([order_id])

