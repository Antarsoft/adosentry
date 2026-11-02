from django.contrib.auth.decorators import login_required
from django.shortcuts import render

from .models import Invoice


@login_required
def invoice_list(request):
    invoices = Invoice.objects.filter(account=request.user.account).order_by("-issued_on")[:100]
    return render(request, "billing/invoice_list.html", {"invoices": invoices})
