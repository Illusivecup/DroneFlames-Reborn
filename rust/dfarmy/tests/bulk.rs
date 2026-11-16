//! Тесты bulk_plan — жадный план массовых улучшений (v1.3.0).
//! Паритет с game/bulk_infrastructure.gd plan(): нехватка бюджета пропускает
//! объект, отрицательные стоимости недопустимы, итоги копятся по ресурсам.

use dfarmy::bulk_plan_core;

fn run(rows: &[&[i64]], budgets: &[i64]) -> (Vec<i64>, Vec<i64>) {
    let mut flat: Vec<i64> = Vec::new();
    let mut off: Vec<i32> = vec![0];
    for r in rows {
        flat.extend_from_slice(r);
        off.push(flat.len() as i32);
    }
    let out = bulk_plan_core(&flat, &off, budgets);
    let k = budgets.len();
    (out[..rows.len()].to_vec(), out[rows.len()..rows.len() + k].to_vec())
}

#[test]
fn greedy_selects_affordable_in_order() {
    // 2 ресурса: деньги, металл. Бюджет 12/1.
    // f0 (5,1) — берём; f1 (10,2) — не хватает металла; f2 (3,0) — берём.
    let (flags, totals) = run(&[&[5, 1], &[10, 2], &[3, 0]], &[12, 1]);
    assert_eq!(flags, vec![1, 0, 1]);
    assert_eq!(totals, vec![8, 1]);
}

#[test]
fn stops_when_budget_exhausted() {
    let (flags, totals) = run(&[&[7], &[7], &[7]], &[10]);
    assert_eq!(flags, vec![1, 0, 0]);
    assert_eq!(totals, vec![7]);
}

#[test]
fn negative_cost_skips_object() {
    let (flags, totals) = run(&[&[-5, 1], &[2, 0]], &[10, 10]);
    assert_eq!(flags, vec![0, 1]);
    assert_eq!(totals, vec![2, 0]);
}

#[test]
fn ragged_row_is_skipped_safely() {
    // Битая строка (ширина не совпадает с числом бюджетов) не роняет план.
    let flat: Vec<i64> = vec![2, 1, 3];
    let off: Vec<i32> = vec![0, 2, 3]; // строка 0 шириной 2 (ок), строка 1 шириной 1 (битая)
    let out = bulk_plan_core(&flat, &off, &[10, 10]);
    assert_eq!(out[0], 1); // первая строка выбрана
    assert_eq!(out[1], 0); // битая строка пропущена
    assert_eq!(out[2], 2);
    assert_eq!(out[3], 1);
}

#[test]
fn empty_input_returns_totals_only() {
    let out = bulk_plan_core(&[], &[0], &[5, 6]);
    assert_eq!(out, vec![0, 0]); // 0 флагов + 2 итога трат (ничего не выбрано)
}

#[test]
fn determinism_same_input_same_output() {
    let a = run(&[&[1, 1], &[2, 2], &[4, 4]], &[9, 9]);
    let b = run(&[&[1, 1], &[2, 2], &[4, 4]], &[9, 9]);
    assert_eq!(a, b);
}

#[test]
fn max_values_no_overflow() {
    // Стоимость ровно по бюджету — выбирается; траты не переполняют i64
    // (суммарные траты всегда <= начального бюджета).
    let big: i64 = i64::MAX;
    let (flags, totals) = run(&[&[big, big]], &[big, big]);
    assert_eq!(flags, vec![1]);
    assert_eq!(totals, vec![big, big]);
    // Вторая такая же уже не по бюджету (остаток 0).
    let (flags2, totals2) = run(&[&[big, big], &[big, big]], &[big, big]);
    assert_eq!(flags2, vec![1, 0]);
    assert_eq!(totals2, vec![big, big]);
}
