
options validvarname=v7 yearcutoff=1950 nodate nonumber;

%let input_csv = /home/u64542512/Credit card transactions - Project - 2.csv;
%let output_folder = /home/u64542512/outputs;
%let output_xlsx = &output_folder.\credit_card_project2_outputs.xlsx;

filename in_csv "&input_csv";

%macro validate_input;
  %if %sysfunc(fexist(in_csv)) = 0 %then %do;
    %put ERROR: Input CSV was not found. Check the INPUT_CSV macro variable.;
    %put ERROR: &input_csv;
    %abort cancel;
  %end;
%mend validate_input;
%validate_input;

options dlcreatedir;
libname makeout "&output_folder";
libname makeout clear;

/* 1. Import the source CSV. */
proc import datafile="&input_csv"
    out=work.raw_transactions
    dbms=csv
    replace;
  guessingrows=max;
  getnames=yes;
run;

/* 2. Standardize column names, parse dates, and create reusable date parts. */
data work.credit_card_txns;
  set work.raw_transactions(
    rename=(
      index=source_index
      City=source_city
      Date=source_date
      Card_Type=source_card_type
      Exp_Type=source_expense_type
      Gender=source_gender
      Amount=source_amount
    )
  );

  length city $80 card_type $20 expense_type $30 gender $1 date_text $20;

  transaction_id = input(strip(vvalue(source_index)), best32.);
  city = strip(source_city);
  card_type = strip(source_card_type);
  expense_type = strip(source_expense_type);
  gender = strip(source_gender);
  date_text = strip(vvalue(source_date));

  if vtype(source_date) = "N" then txn_date = source_date;
  else txn_date = input(date_text, anydtdte.);

  amount = input(strip(vvalue(source_amount)), comma32.);

  month_start = intnx("month", txn_date, 0, "b");
  weekday_num = weekday(txn_date);

  format txn_date yymmdd10. month_start monyy7. amount comma18.;
  label
    transaction_id = "Source Index"
    city = "City"
    date_text = "Original Date Text"
    txn_date = "Transaction Date"
    month_start = "Transaction Month"
    weekday_num = "SAS Weekday Number"
    card_type = "Card Type"
    expense_type = "Expense Type"
    gender = "Gender"
    amount = "Transaction Amount";

  keep transaction_id city date_text txn_date month_start weekday_num
       card_type expense_type gender amount;
run;

/* 3. Dataset profile and quality checks. */
proc sql;
  create table work.data_profile as
  select
      count(*) as total_transactions format=comma12.,
      count(distinct city) as unique_cities format=comma12.,
      count(distinct card_type) as unique_card_types,
      count(distinct expense_type) as unique_expense_types,
      min(txn_date) as first_transaction_date format=yymmdd10.,
      max(txn_date) as last_transaction_date format=yymmdd10.,
      sum(amount) as total_spend format=comma18.,
      min(amount) as minimum_transaction format=comma18.,
      mean(amount) as average_transaction format=comma18.2,
      max(amount) as maximum_transaction format=comma18.
  from work.credit_card_txns;

  create table work.data_quality_checks as
  select
      sum(missing(transaction_id)) as missing_transaction_id,
      sum(missing(city)) as missing_city,
      sum(missing(txn_date)) as missing_transaction_date,
      sum(missing(card_type)) as missing_card_type,
      sum(missing(expense_type)) as missing_expense_type,
      sum(missing(gender)) as missing_gender,
      sum(missing(amount)) as missing_amount,
      count(*) - count(distinct transaction_id) as duplicate_transaction_ids
  from work.credit_card_txns;
quit;


/* Task 1: Top 5 cities by total spend and their percentage contribution. */
proc sql outobs=5;
  create table work.task1_top5_cities as
  select
      city,
      sum(amount) as total_spend format=comma18.,
      calculated total_spend /
        (select sum(amount) from work.credit_card_txns) * 100
        as pct_total_spend format=10.4
  from work.credit_card_txns
  group by city
  order by total_spend desc, city;
quit;


/* Task 2: Highest spend month for each card type. */
proc sql;
  create table work.monthly_card_spend as
  select
      card_type,
      month_start,
      sum(amount) as monthly_spend format=comma18.
  from work.credit_card_txns
  group by card_type, month_start;
quit;

proc sort data=work.monthly_card_spend;
  by card_type descending monthly_spend month_start;
run;

data work.task2_highest_month_by_card;
  set work.monthly_card_spend;
  by card_type;
  if first.card_type;
  format month_start monyy7.;
run;


/* Task 3: Transaction row where each card type first reaches 1,000,000 cumulative spend. */
proc sort data=work.credit_card_txns out=work.transactions_by_card;
  by card_type txn_date transaction_id;
run;

data work.card_running_spend;
  set work.transactions_by_card;
  by card_type;
  if first.card_type then cumulative_spend = 0;
  cumulative_spend + amount;
  format cumulative_spend comma18.;
run;

data work.card_first_over_million;
  set work.card_running_spend;
  where cumulative_spend >= 1000000;
run;

proc sort data=work.card_first_over_million;
  by card_type txn_date transaction_id;
run;

data work.task3_card_million_reached;
  set work.card_first_over_million;
  by card_type;
  if first.card_type;
  keep transaction_id city date_text txn_date card_type expense_type
       gender amount cumulative_spend;
run;


/* Task 4: City with the lowest percentage contribution to Gold card spend. */
proc sql outobs=1;
  create table work.task4_lowest_gold_city as
  select
      city,
      sum(amount) as gold_spend format=comma18.,
      calculated gold_spend /
        (select sum(amount)
         from work.credit_card_txns
         where upcase(card_type) = "GOLD") * 100
        as pct_gold_spend format=12.6
  from work.credit_card_txns
  where upcase(card_type) = "GOLD"
  group by city
  order by pct_gold_spend, city;
quit;


/* Task 5: Highest and lowest expense type by city. */
proc sql;
  create table work.city_expense_spend as
  select
      city,
      expense_type,
      sum(amount) as expense_spend format=comma18.
  from work.credit_card_txns
  group by city, expense_type;
quit;

proc sort data=work.city_expense_spend out=work.city_expense_desc;
  by city descending expense_spend expense_type;
run;

data work.city_highest_expense;
  set work.city_expense_desc;
  by city;
  if first.city;
  length highest_expense_type $30;
  highest_expense_type = expense_type;
  highest_expense_spend = expense_spend;
  keep city highest_expense_type highest_expense_spend;
  format highest_expense_spend comma18.;
run;

proc sort data=work.city_expense_spend out=work.city_expense_asc;
  by city expense_spend expense_type;
run;

data work.city_lowest_expense;
  set work.city_expense_asc;
  by city;
  if first.city;
  length lowest_expense_type $30;
  lowest_expense_type = expense_type;
  lowest_expense_spend = expense_spend;
  keep city lowest_expense_type lowest_expense_spend;
  format lowest_expense_spend comma18.;
run;

data work.task5_city_expense_extremes;
  merge work.city_highest_expense work.city_lowest_expense;
  by city;
run;


/* Task 6: Percentage contribution of female spend by expense type. */
proc sql;
  create table work.task6_female_pct_by_expense as
  select
      expense_type,
      sum(case when upcase(gender) = "F" then amount else 0 end)
        as female_spend format=comma18.,
      sum(amount) as total_spend format=comma18.,
      calculated female_spend / calculated total_spend * 100
        as female_pct_contribution format=10.4
  from work.credit_card_txns
  group by expense_type
  order by expense_type;
quit;


/* Task 7: Card and expense type with highest month-over-month growth in Jan-2014.
   Growth is measured as the absolute increase from Dec-2013 to Jan-2014.
   Growth percentage is also calculated for interpretation. */
proc sql;
  create table work.combo_monthly_spend as
  select
      card_type,
      expense_type,
      month_start,
      sum(amount) as monthly_spend format=comma18.
  from work.credit_card_txns
  group by card_type, expense_type, month_start;
quit;

proc sort data=work.combo_monthly_spend;
  by card_type expense_type month_start;
run;

data work.combo_monthly_growth;
  set work.combo_monthly_spend;
  by card_type expense_type;
  retain prior_month_start prior_monthly_spend;

  if first.expense_type then call missing(prior_month_start, prior_monthly_spend);

  previous_month_start = prior_month_start;
  previous_month_spend = prior_monthly_spend;
  mom_growth_amount = monthly_spend - previous_month_spend;
  if previous_month_spend > 0 then
    mom_growth_pct = mom_growth_amount / previous_month_spend * 100;

  prior_month_start = month_start;
  prior_monthly_spend = monthly_spend;

  format previous_month_start month_start monyy7.
         previous_month_spend monthly_spend mom_growth_amount comma18.
         mom_growth_pct 10.4;
  drop prior_:;
run;

data work.jan_2014_growth;
  set work.combo_monthly_growth;
  where month_start = "01JAN2014"d and previous_month_start = "01DEC2013"d;
run;

proc sort data=work.jan_2014_growth;
  by descending mom_growth_amount card_type expense_type;
run;

data work.task7_highest_mom_growth_jan2014;
  set work.jan_2014_growth(obs=1);
run;


/* Task 8: Weekend city with the highest spend per transaction.
   In SAS, WEEKDAY returns 1 for Sunday and 7 for Saturday. */
proc sql outobs=1;
  create table work.task8_weekend_best_ratio as
  select
      city,
      sum(amount) as total_weekend_spend format=comma18.,
      count(*) as weekend_transactions format=comma12.,
      calculated total_weekend_spend / calculated weekend_transactions
        as spend_per_weekend_transaction format=comma18.2
  from work.credit_card_txns
  where weekday_num in (1, 7)
  group by city
  order by spend_per_weekend_transaction desc, city;
quit;


/* Task 9: City that reached its 500th transaction in the fewest days. */
proc sort data=work.credit_card_txns out=work.transactions_by_city;
  by city txn_date transaction_id;
run;

data work.city_500th_transaction;
  set work.transactions_by_city;
  by city;
  retain first_transaction_date transaction_number;

  if first.city then do;
    first_transaction_date = txn_date;
    transaction_number = 0;
  end;

  transaction_number + 1;

  if transaction_number = 500 then do;
    transaction_500_date = txn_date;
    transaction_500_id = transaction_id;
    days_to_500th_transaction = transaction_500_date - first_transaction_date;
    output;
  end;

  keep city first_transaction_date transaction_500_date transaction_500_id
       days_to_500th_transaction;
  format first_transaction_date transaction_500_date yymmdd10.;
run;

proc sort data=work.city_500th_transaction;
  by days_to_500th_transaction city;
run;

data work.task9_least_days_to_500;
  set work.city_500th_transaction(obs=1);
run;


/* 4. Export all important outputs to a multi-sheet workbook. */
ods excel file="&output_xlsx"
  options(
    embedded_titles="yes"
    frozen_headers="yes"
    sheet_interval="proc"
    autofilter="all"
  );

ods excel options(sheet_name="Profile");
title "Dataset Profile";
proc print data=work.data_profile noobs label;
run;

ods excel options(sheet_name="Quality");
title "Data Quality Checks";
proc print data=work.data_quality_checks noobs label;
run;

ods excel options(sheet_name="Task1_Top5Cities");
title "Task 1 - Top 5 Cities by Spend";
proc print data=work.task1_top5_cities noobs label;
run;


ods excel options(sheet_name="Task2_CardMonths");
title "Task 2 - Highest Spend Month by Card Type";
proc print data=work.task2_highest_month_by_card noobs label;
run;


ods excel options(sheet_name="Task3_Cumulative1M");
title "Task 3 - First Transaction Reaching 1,000,000 Cumulative Spend";
proc print data=work.task3_card_million_reached noobs label;
run;


ods excel options(sheet_name="Task4_GoldLowest");
title "Task 4 - Lowest City Contribution to Gold Card Spend";
proc print data=work.task4_lowest_gold_city noobs label;
run;

ods excel options(sheet_name="Task5_CityExpense");
title "Task 5 - Highest and Lowest Expense Type by City";
proc print data=work.task5_city_expense_extremes noobs label;
run;

ods excel options(sheet_name="Task6_FemalePct");
title "Task 6 - Female Spend Percentage by Expense Type";
proc print data=work.task6_female_pct_by_expense noobs label;
run;

ods excel options(sheet_name="Task7_MoMGrowth");
title "Task 7 - Highest Month-over-Month Growth in Jan-2014";
proc print data=work.task7_highest_mom_growth_jan2014 noobs label;
run;

ods excel options(sheet_name="Task8_WeekendRatio");
title "Task 8 - Best Weekend Spend per Transaction Ratio";
proc print data=work.task8_weekend_best_ratio noobs label;
run;

ods excel options(sheet_name="Task9_500thTxn");
title "Task 9 - Fastest City to Reach 500 Transactions";
proc print data=work.task9_least_days_to_500 noobs label;
run;

ods excel close;
title;

%put NOTE: Project output workbook created at &output_xlsx;
